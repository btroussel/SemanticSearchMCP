"""User-authorized folders sharing one local multimodal runtime."""
from __future__ import annotations

import io
import json
import logging
import os
import secrets
import threading
import time
import uuid
from contextlib import ExitStack, asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, Response
from pydantic import BaseModel, Field

from .index import MAX_DUPLICATES, Index
from .service import Worker, SearchRequest
from .settings import ModelSettings, validate_max_tokens
from .access import AccessRequest, ProjectAccess, project_header

log = logging.getLogger(__name__)


class SourceRequest(BaseModel):
    path: str = Field(min_length=1)
    name: str = Field(default="", max_length=100)
    kinds: list[str] = Field(default_factory=lambda: ["code", "documents", "images"])
    excludes: list[str] = Field(default_factory=list, max_length=100)


class WorkspaceSearch(SearchRequest):
    source_id: str = ""
    asset_kind: str = ""


class SettingsRequest(ModelSettings):
    """Partial update: omitted fields retain their current values."""


class Workspace:
    def __init__(self, state: Path, embedder, interval=300, watch=True, max_tokens: int | None = None):
        self.state = state.expanduser().resolve()
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.state, 0o700)
        self.embedder, self.interval, self.watch = embedder, interval, watch
        self.image_encoder_available = embedder.images
        self.settings_path = self.state / "settings.json"
        if self.settings_path.exists():
            saved = SettingsRequest(**json.loads(self.settings_path.read_text())).model_dump(exclude_unset=True)
            # --text-only remains a hard service restriction, including on restart.
            saved["images"] = saved.get("images", embedder.images) and self.image_encoder_available
            if max_tokens is not None:
                saved["max_tokens"] = validate_max_tokens(max_tokens)
            self.embedder.configure(**saved)
        if max_tokens is not None:
            self.embedder.set_max_tokens(validate_max_tokens(max_tokens))
        self.lock = threading.RLock()
        self.sources = {}
        self.access = ProjectAccess(self.state)
        self.retired = []
        self.running = False
        self.config_path = self.state / "sources.json"
        token_path = self.state / "access.key"
        if not token_path.exists():
            fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as file:
                file.write(secrets.token_urlsafe(32))
        os.chmod(token_path, 0o600)
        self.token = token_path.read_text().strip()
        if self.config_path.exists():
            for config in json.loads(self.config_path.read_text()):
                if not isinstance(config.get("id"), str) or not all(c in "0123456789abcdef" for c in config["id"]) or len(config["id"]) != 32:
                    raise ValueError("Invalid source identifier in saved configuration")
                self.sources[config["id"]] = self._entry(config)
        # Finish a queued purge if the app was closed during an in-flight embedding batch.
        for database in self.state.glob("*.sqlite"):
            identifier = database.stem
            if len(identifier) == 32 and all(c in "0123456789abcdef" for c in identifier) and identifier not in self.sources:
                for suffix in (".sqlite", ".sqlite-wal", ".sqlite-shm"):
                    (self.state / f"{identifier}{suffix}").unlink(missing_ok=True)

    def _entry(self, config):
        entry = {"config": config, "worker": None, "error": None}
        try:
            if "images" in config["kinds"] and not self.embedder.images:
                raise ValueError("Enable image encoding in settings to index this source")
            index = Index(Path(config["path"]), self.state / f"{config['id']}.sqlite", self.embedder,
                          config["excludes"], config["kinds"], rebuild_on_model_change=True)
            entry["worker"] = Worker(index, self.interval, self.watch)
        except Exception as exc:
            entry["error"] = str(exc)
        return entry

    def _save(self):
        temporary = self.config_path.with_suffix(".tmp")
        temporary.write_text(json.dumps([e["config"] for e in self.sources.values()], indent=2))
        os.chmod(temporary, 0o600)
        temporary.replace(self.config_path)

    def update_settings(self, request: SettingsRequest):
        with self.lock, ExitStack() as stack:
            current = self.embedder.configuration()
            options = ModelSettings(**{**current, **request.model_dump(exclude_unset=True)}).model_dump()
            if options["images"] and not self.image_encoder_available:
                raise ValueError("This service was started with --text-only; image encoding is unavailable")
            if not options["images"] and any("images" in e["config"]["kinds"] for e in self.sources.values()):
                raise ValueError("Remove sources authorizing images before disabling image encoding; original files are kept")
            workers = [e["worker"] for e in self.sources.values() if e["worker"]]
            changed = options != current
            rebuild = any(options[key] != current[key] for key in ("max_tokens", "dimensions", "precision", "images"))
            rebuild |= options["images"] and options["image_tokens"] != current["image_tokens"]
            if changed:
                # Finish in-flight indexing before changing the shared runtime.
                # Searches and source mutations use the workspace lock too.
                for worker in workers:
                    worker.reset_requested.set()
                    def resume(worker=worker):
                        worker.reset_requested.clear()
                        worker.request()
                    stack.callback(resume)
                for worker in workers:
                    stack.enter_context(worker.index.index_lock)
            temporary = self.settings_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(options, indent=2))
            os.chmod(temporary, 0o600)
            temporary.replace(self.settings_path)
            if changed:
                self.embedder.configure(**options)
                for worker in workers:
                    if rebuild:
                        worker.index.reset_token_limit()
                        worker.phase = "indexing"
                    else:
                        with worker.index.lock:
                            worker.index.query_cache.clear()
            return {**options, "reindex_queued": rebuild and bool(workers)}

    def settings(self):
        return {**self.embedder.configuration(), "image_encoder_available": self.image_encoder_available}

    def start(self):
        with self.lock:
            self.running = True
            for entry in self.sources.values():
                if entry["worker"]:
                    entry["worker"].start()

    def stop(self):
        with self.lock:
            self.running = False
            workers = [e["worker"] for e in self.sources.values() if e["worker"]] + self.retired
            for worker in workers:
                worker.stop.set()
                worker.pending.set()
        for worker in workers:
            for thread in worker.threads:
                thread.join(timeout=5)

    def add(self, request: SourceRequest):
        path = Path(request.path).expanduser()
        if not path.is_absolute() or not path.is_dir():
            raise ValueError("Select an existing absolute folder")
        path = path.resolve()
        kinds = sorted(set(request.kinds))
        if not kinds or set(kinds) - {"code", "documents", "images"}:
            raise ValueError("Choose code, documents, and/or images")
        if "images" in kinds and not getattr(self.embedder, "images", False):
            raise ValueError("This service was started without the image encoder")
        if path.is_relative_to(self.state):
            raise ValueError("The service's own data folder cannot be indexed")
        with self.lock:
            for entry in self.sources.values():
                other = Path(entry["config"]["path"])
                if path.is_relative_to(other) or other.is_relative_to(path):
                    raise ValueError("This folder overlaps an existing source; remove that source to change its scope")
            excludes = list(request.excludes)
            for internal in (self.state, getattr(self.embedder, "path", self.state)):
                if internal.is_relative_to(path):
                    excludes.append(internal.relative_to(path).as_posix() + "/")
            config = {"id": uuid.uuid4().hex, "name": request.name.strip() or path.name,
                      "path": str(path), "kinds": kinds, "excludes": excludes, "added_at": time.time()}
            entry = self._entry(config)
            if entry["error"]:
                raise ValueError(entry["error"])
            self.sources[config["id"]] = entry
            self._save()
            if self.running:
                entry["worker"].start()
            return config

    def remove(self, source_id):
        # Holding this lock also lets any active read finish before revocation returns.
        with self.lock:
            if source_id not in self.sources:
                raise ValueError("Source is not authorized")
            self.access.revoke_source(Path(self.sources[source_id]["config"]["path"]))
            entry = self.sources.pop(source_id)
            self._save()
            worker = entry["worker"]
            if worker:
                worker.stop.set()
                worker.pending.set()
                self.retired.append(worker)

        def purge():
            if worker:
                for thread in worker.threads:
                    thread.join()
                with worker.index.lock:
                    worker.index.db.close()
            for suffix in (".sqlite", ".sqlite-wal", ".sqlite-shm"):
                (self.state / f"{source_id}{suffix}").unlink(missing_ok=True)
            if worker:
                with self.lock:
                    if worker in self.retired:
                        self.retired.remove(worker)
        threading.Thread(target=purge, daemon=True).start()
        return {"removed": source_id, "access_revoked": True, "cache_cleanup": "queued"}

    def scopes(self, project: Path, additional=True):
        return self.access.scopes(project, [e["config"] for e in self.sources.values()], additional)

    def check_path(self, project: Path | None, source_id: str, path: str):
        if project is None:
            return
        # Repository.path checks symlinks, traversal, types and ignore rules.
        index = self.index(source_id)
        index.repo.path(path)
        prefixes = [s["path_prefix"] for s in self.scopes(project).get(source_id, [])]
        if not any(path.startswith(p) for p in prefixes):
            raise ValueError("Folder is outside this MCP project. Grant access in the app's assistant settings")

    def status(self, project: Path | None = None):
        with self.lock:
            scopes = self.scopes(project) if project is not None else None
            sources = []
            for entry in self.sources.values():
                sid = entry["config"]["id"]
                if scopes is not None and sid not in scopes:
                    continue
                stats = entry["worker"].status() if entry["worker"] else {"phase": "error", "error": entry["error"], "files": 0, "chunks": 0}
                if scopes is not None:
                    # Do not expose counts, skipped paths or errors from sibling projects.
                    prefixes = [s["path_prefix"] for s in scopes[sid]]
                    if entry["worker"]:
                        index = entry["worker"].index
                        with index.lock:
                            paths = [r[0] for r in index.db.execute("SELECT path FROM chunks")
                                     if any(r[0].startswith(p) for p in prefixes)]
                        stats["files"], stats["chunks"] = len(set(paths)), len(paths)
                    stats["last_sync"] = None
                    stats["error"] = "Index unavailable; inspect it in the app" if stats.get("error") else None
                    stats["allowed_paths"] = scopes[sid]
                sources.append({**stats, **entry["config"]})
            return {"service": "local-search", "sources": sources, "model_loaded": self.embedder.model is not None,
                    **({"project": str(project), "default_scope": "project"} if project is not None else {}),
                    "device": self.embedder.device, "image_search": getattr(self.embedder, "images", False),
                    **self.settings(),
                    "files": sum(s["files"] for s in sources), "chunks": sum(s["chunks"] for s in sources)}

    def index(self, source_id):
        if not source_id:
            if len(self.sources) != 1:
                raise ValueError("Specify source_id from list_sources")
            source_id = next(iter(self.sources))
        entry = self.sources.get(source_id)
        if not entry:
            raise ValueError("Source is not authorized")
        if not entry["worker"]:
            raise ValueError(entry["error"] or "Source unavailable")
        return entry["worker"].index

    def search(self, request: WorkspaceSearch, project: Path | None = None):
        if request.asset_kind and request.asset_kind not in {"code", "documents", "images"}:
            raise ValueError("asset_kind must be code, documents, or images")
        start = time.perf_counter()
        with self.lock:
            scopes = self.scopes(project, additional=bool(request.source_id)) if project is not None else None
            if scopes is not None and request.source_id and request.source_id not in scopes:
                raise ValueError("Folder is outside this MCP project. Grant access in the app's assistant settings")
            identifiers = [request.source_id] if request.source_id else list(scopes if scopes is not None else self.sources)
            results, issues, stale = [], [], []
            for identifier in identifiers:
                entry = self.sources.get(identifier)
                if entry is None:
                    raise ValueError("Source is not authorized")
                if not entry["worker"]:
                    issues.append({"source_id": identifier, "error": entry["error"]})
                    continue
                index = entry["worker"].index
                try:
                    hit = index.search(request.query, limit=30, path_filter=request.path_filter,
                                       mode=request.mode, max_chars=request.max_chars, asset_kind=request.asset_kind,
                                       allowed_prefixes=[s["path_prefix"] for s in scopes[identifier]] if scopes is not None else None)
                except Exception as exc:
                    issues.append({"source_id": identifier, "error": str(exc)})
                    continue
                stale.extend({"source_id": identifier, "path": p} for p in hit.get("stale_paths", []))
                if hit.get("degraded"):
                    issues.append({"source_id": identifier, "error": hit["degraded"]})
                for result in hit["results"]:
                    results.append({**result, "source_id": identifier, "source_name": entry["config"]["name"],
                                    "source_path": entry["config"]["path"], "mode": hit["mode"],
                                    "duplicates": [{"source_id": identifier, **d} for d in result["duplicates"]]})
            results.sort(key=lambda r: r["cosine"] if r["cosine"] is not None and request.mode != "hybrid" else r["score"], reverse=True)
            # Copies in other sources join the best-ranked result instead of taking another slot.
            distinct, by_content = [], {}
            for result in results:
                first = by_content.get(result["content_id"])
                if first is None:
                    by_content[result["content_id"]] = result
                    distinct.append(result)
                    continue
                extra = [{"source_id": result["source_id"], "path": result["path"]}] + result["duplicates"]
                room = max(0, MAX_DUPLICATES - len(first["duplicates"]))
                first["duplicates"] += extra[:room]
                first["duplicates_omitted"] += max(0, len(extra) - room) + result["duplicates_omitted"]
            bounded, remaining = [], request.max_chars
            for result in distinct[:request.limit]:
                code = result["code"]
                result["code"] = code[:remaining]
                result["truncated"] |= len(code) > remaining
                remaining -= len(result["code"])
                bounded.append(result)
                if remaining <= 0:
                    break
            return {"query": request.query, "results": bounded, "issues": issues, "stale_paths": stale,
                    "elapsed_ms": round((time.perf_counter() - start) * 1000, 2)}

    def thumbnail(self, source_id, path):
        with self.lock:
            index = self.index(source_id)
            if not index._allowed(path):
                raise ValueError("Path excluded from this source")
            with index.repo.image(path) as image:
                output = io.BytesIO()
                image.save(output, format="PNG")
                return output.getvalue()


def create_workspace_app(workspace: Workspace):
    @asynccontextmanager
    async def lifespan(app):
        workspace.start()
        yield
        workspace.stop()

    app = FastAPI(title="Local Search", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.workspace = workspace

    @app.middleware("http")
    async def authorize(request: Request, call_next):
        # No CORS: browsers on other origins cannot obtain the native app's private key.
        host = request.headers.get("host", "").split(":")[0]
        if host not in {"localhost", "127.0.0.1", "testserver"}:
            return Response(status_code=403)
        header = request.headers.get("authorization", "")
        if not secrets.compare_digest(header, f"Bearer {workspace.token}"):
            return Response(status_code=401)
        request.state.project = None
        if "x-local-search-project" in request.headers:
            from fastapi.responses import JSONResponse
            try:
                request.state.project = project_header(request.headers["x-local-search-project"])
            except ValueError as exc:
                return JSONResponse({"detail": str(exc)}, status_code=400)
            allowed = ((request.method == "GET" and request.url.path in {"/status", "/sources", "/file", "/image"})
                       or (request.method == "GET" and request.url.path.startswith("/symbol/"))
                       or (request.method == "POST" and request.url.path in {"/search", "/reindex"}))
            if not allowed:
                return JSONResponse({"detail": "Manage folder access and settings in the Mac app"}, status_code=403)
        response = await call_next(request)
        if request.state.project is not None:
            response.headers["X-Local-Search-Scoped"] = "1"
        return response

    @app.exception_handler(ValueError)
    async def invalid(request, exc):
        from fastapi.responses import JSONResponse
        return JSONResponse({"detail": str(exc)}, status_code=400)

    @app.get("/status")
    def status(http: Request):
        return workspace.status(http.state.project)

    @app.get("/sources")
    def sources(http: Request):
        status = workspace.status(http.state.project)
        return {k: v for k, v in status.items() if k in {"sources", "project", "default_scope"}}

    @app.get("/mcp-access")
    def mcp_access(project: str):
        with workspace.lock:
            return workspace.access.get(project)

    @app.put("/mcp-access")
    def update_mcp_access(request: AccessRequest):
        with workspace.lock:
            return workspace.access.save(request, [e["config"] for e in workspace.sources.values()])

    @app.get("/settings")
    def settings():
        with workspace.lock:
            return workspace.settings()

    @app.put("/settings")
    def update_settings(request: SettingsRequest):
        return workspace.update_settings(request)

    @app.post("/sources")
    def add_source(request: SourceRequest):
        return workspace.add(request)

    @app.delete("/sources/{source_id}")
    def remove_source(source_id: str):
        return workspace.remove(source_id)

    @app.post("/search")
    def search(request: WorkspaceSearch, http: Request):
        return workspace.search(request, http.state.project)

    @app.get("/file")
    def read_file(http: Request, source_id: str, path: str, start_line: int = 1, max_lines: int = 120):
        with workspace.lock:
            workspace.check_path(http.state.project, source_id, path)
            return workspace.index(source_id).read_file(path, start_line, max_lines)

    @app.get("/symbol/{identifier}")
    def read_symbol(http: Request, identifier: str, source_id: str):
        with workspace.lock:
            index = workspace.index(source_id)
            with index.lock:
                row = index.db.execute("SELECT path FROM chunks WHERE id=?", (identifier,)).fetchone()
            if row is None:
                raise ValueError("Symbol not found; search again after indexing")
            workspace.check_path(http.state.project, source_id, row[0])
            return index.read_symbol(identifier)

    @app.get("/image")
    def image(http: Request, source_id: str, path: str):
        with workspace.lock:
            workspace.check_path(http.state.project, source_id, path)
            return Response(workspace.thumbnail(source_id, path), media_type="image/png", headers={"Cache-Control": "no-store"})

    @app.post("/reindex")
    def reindex(http: Request, source_id: str = ""):
        with workspace.lock:
            scopes = workspace.scopes(http.state.project, additional=bool(source_id)) if http.state.project is not None else None
            if source_id:
                if scopes is not None and source_id not in scopes:
                    raise ValueError("Folder is outside this MCP project. Grant access in the app's assistant settings")
                workspace.index(source_id)
                entries = [workspace.sources[source_id]]
            else:
                entries = [entry for sid, entry in workspace.sources.items() if scopes is None or sid in scopes]
            for entry in entries:
                if entry["worker"]:
                    entry["worker"].request()
            return {"queued": True}

    return app
