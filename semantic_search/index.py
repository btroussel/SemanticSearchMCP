"""Transactional SQLite index, cached vectors, and hybrid retrieval."""
from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from pathlib import Path

import numpy as np
import pathspec

from .chunks import CHUNK_VERSION, Chunk, chunk_id, split_file
from .files import Repository, digest
from .settings import DEFAULT_MAX_TOKENS

MAX_DUPLICATES = 10


def duplicate_key(row: dict) -> tuple:
    """Identify the same chunk in byte-identical files (or identically extracted documents)."""
    # Image text names the file, so the pixel hash alone identifies copies.
    return (row["file_hash"], row["kind"], row["start"], row["end"], "" if row["kind"] == "image" else row["text"])


def words(text: str) -> str:
    text = re.sub(r"([a-z])([A-Z])", r"\1 \2", text)
    return " ".join(re.findall(r"[a-zA-Z0-9]+", text.lower()))


class Index:
    def __init__(self, repo: Path, database: Path, embedder, excludes: list[str] | None = None, kinds: list[str] | None = None,
                 rebuild_on_model_change: bool = False):
        self.repo = Repository(repo, kinds)
        self.query_task = "code" if kinds is None or kinds == ["code"] else "search"
        self.embedder = embedder
        self.excludes = excludes or []
        self.exclude_spec = pathspec.PathSpec.from_lines("gitignore", self.excludes)
        database.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(database, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.index_lock = threading.Lock()
        self.revision = 0
        self.matrix_revision = -1
        self.rows = []
        self.matrix = np.empty((0, embedder.dimensions), dtype=np.float32)
        self.keys, self.copies = [], {}
        self.query_cache = {}
        self.last_sync = None
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, hash TEXT);
            CREATE TABLE IF NOT EXISTS chunks (
                id TEXT PRIMARY KEY, path TEXT, symbol TEXT, kind TEXT,
                start INTEGER, end INTEGER, parent_id TEXT, text TEXT, vector BLOB);
            CREATE INDEX IF NOT EXISTS chunks_path ON chunks(path);
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(id UNINDEXED, content);
            CREATE TABLE IF NOT EXISTS embedding_cache (hash TEXT PRIMARY KEY, vector BLOB);
        """)
        expected = {"repo": str(self.repo.root), "model": embedder.fingerprint,
                    "chunk_version": CHUNK_VERSION, "excludes": json.dumps(self.excludes),
                    "max_tokens": str(getattr(embedder, "max_tokens", DEFAULT_MAX_TOKENS))}
        if kinds is not None:
            expected["kinds"] = json.dumps(sorted(kinds))
            expected["extract_version"] = "1"
        previous = dict(self.db.execute("SELECT key, value FROM meta"))
        differences = {k for k, v in expected.items() if previous.get(k) != v}
        if previous and differences:
            rebuildable = {"max_tokens", "chunk_version"} | ({"model"} if rebuild_on_model_change else set())
            if differences <= rebuildable and previous.get("chunk_version") in {"3", CHUNK_VERSION}:
                # Token-budget changes invalidate both chunks and cached vectors.
                # Upgrade existing app indexes without losing folder authorization.
                self.reset_token_limit()
            else:
                self.db.close()
                raise ValueError("Index configuration changed. Use a new --db path or remove the old index to rebuild.")
        self.db.executemany("INSERT OR REPLACE INTO meta VALUES (?, ?)", expected.items())
        self.db.commit()

    def reset_token_limit(self):
        """Caller holds index_lock when changing a running index's model settings."""
        with self.lock, self.db:
            for table in ("chunks_fts", "chunks", "files", "embedding_cache"):
                self.db.execute(f"DELETE FROM {table}")
            self.db.executemany("INSERT OR REPLACE INTO meta VALUES (?, ?)", [
                ("max_tokens", str(getattr(self.embedder, "max_tokens", DEFAULT_MAX_TOKENS))),
                ("chunk_version", CHUNK_VERSION),
                ("model", self.embedder.fingerprint),
            ])
            self.query_cache.clear()
            self.rows, self.keys, self.copies = [], [], {}
            self.matrix = np.empty((0, self.embedder.dimensions), dtype=np.float32)
            self.last_sync = None
            self.revision += 1

    def _allowed(self, path):
        return not self.exclude_spec.match_file(path)

    def sync(self, changed: set[str] | None = None, cancel: threading.Event | None = None):
        with self.index_lock:
            start = time.perf_counter()
            discovered = {p for p in self.repo.files() if self._allowed(p)}
            with self.lock:
                existing = dict(self.db.execute("SELECT path, hash FROM files"))
            targets = discovered if changed is None else discovered.intersection(changed)
            removed = set(existing) - discovered
            stats = {"changed_files": 0, "deleted_files": len(removed), "embedded_chunks": 0, "cached_chunks": 0, "skipped_files": []}
            # Remove deleted/ignored files immediately. Other files remain searchable.
            with self.lock, self.db:
                for path in removed:
                    self._delete(path)
                if removed:
                    self.revision += 1
            # Publish source code first, then longer research/documentation files.
            def priority(path):
                suffix = Path(path).suffix
                return (1 if suffix in {".py", ".ts", ".js", ".rs", ".go", ".cpp", ".c"} else
                        2 if suffix not in {".md", ".rst", ".txt"} else 3, path)
            for path in sorted(targets, key=priority):
                if cancel is not None and cancel.is_set():
                    break
                try:
                    source = self.repo.read(path)
                    file_hash = self.repo.fingerprint(path, source)
                except Exception as exc:
                    stats["skipped_files"].append({"path": path, "error": str(exc)[:200]})
                    with self.lock, self.db:
                        self._delete(path)
                        self.revision += 1
                    continue
                if existing.get(path) == file_hash:
                    continue
                is_image = self.repo.kind(path) == "images"
                try:
                    chunks = [Chunk(chunk_id(path, path, "image", 1), path, Path(path).name, "image", 1, 1, None, source)] if is_image else split_file(
                        path, source, getattr(self.embedder, "max_tokens", DEFAULT_MAX_TOKENS),
                        getattr(self.embedder, "count_tokens", None))
                except ValueError as exc:
                    stats["skipped_files"].append({"path": path, "error": str(exc)[:200]})
                    with self.lock, self.db:
                        self._delete(path)
                        self.revision += 1
                    continue
                keys = [digest(c.document + file_hash) if is_image else digest(c.document) for c in chunks]
                vectors = {}
                with self.lock:
                    for key in keys:
                        row = self.db.execute("SELECT vector FROM embedding_cache WHERE hash=?", (key,)).fetchone()
                        if row:
                            vectors[key] = bytes(row[0])
                            stats["cached_chunks"] += 1
                missing = {key: c.document for key, c in zip(keys, chunks) if key not in vectors}
                entries = list(missing.items())
                # Small batches let interactive searches acquire the model between updates.
                for offset in range(0, len(entries), 4):
                    if cancel is not None and cancel.is_set():
                        return stats
                    batch = entries[offset:offset + 4]
                    if is_image:
                        with self.repo.image(path) as image:
                            encoded = self.embedder.encode([image])
                    else:
                        encoded = self.embedder.encode([text for _, text in batch])
                    for (key, _), vector in zip(batch, encoded):
                        vectors[key] = np.asarray(vector, dtype=np.float32).tobytes()
                    stats["embedded_chunks"] += len(batch)
                # If a file changed during inference, do not publish a stale replacement.
                try:
                    if self.repo.fingerprint(path) != file_hash or (cancel is not None and cancel.is_set()):
                        continue
                except (OSError, UnicodeError, ValueError):
                    continue
                with self.lock, self.db:
                    self._delete(path)
                    self.db.executemany("INSERT OR IGNORE INTO embedding_cache VALUES (?, ?)", vectors.items())
                    for c, key in zip(chunks, keys):
                        self.db.execute("INSERT INTO chunks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                                        (c.id, c.path, c.symbol, c.kind, c.start, c.end, c.parent_id, c.text, vectors[key]))
                        self.db.execute("INSERT INTO chunks_fts VALUES (?, ?)",
                                        (c.id, words(c.path + " " + c.symbol + " " + c.text)))
                    self.db.execute("INSERT INTO files VALUES (?, ?)", (path, file_hash))
                    self.revision += 1
                stats["changed_files"] += 1
            stats["seconds"] = round(time.perf_counter() - start, 3)
            stats["completed_at"] = time.time()
            self.last_sync = stats
            return stats

    def _delete(self, path):
        ids = [r[0] for r in self.db.execute("SELECT id FROM chunks WHERE path=?", (path,))]
        self.db.executemany("DELETE FROM chunks_fts WHERE id=?", [(i,) for i in ids])
        self.db.execute("DELETE FROM chunks WHERE path=?", (path,))
        self.db.execute("DELETE FROM files WHERE path=?", (path,))

    def status(self):
        with self.lock:
            return {"repo": str(self.repo.root), "files": self.db.execute("SELECT count(*) FROM files").fetchone()[0],
                    "chunks": self.db.execute("SELECT count(*) FROM chunks").fetchone()[0],
                    "dimensions": self.embedder.dimensions, "device": self.embedder.device,
                    "max_tokens": getattr(self.embedder, "max_tokens", DEFAULT_MAX_TOKENS),
                    "model_loaded": self.embedder.model is not None, "last_sync": self.last_sync,
                    "gpu_memory": getattr(self.embedder, "memory", {}),
                    "excludes": self.excludes, "vector_search": "exact normalized dot product"}

    def _snapshot(self):
        with self.lock:
            if self.matrix_revision != self.revision:
                self.rows = [dict(r) for r in self.db.execute("SELECT chunks.*, files.hash AS file_hash FROM chunks JOIN files USING(path)")]
                self.matrix = np.stack([np.frombuffer(r.pop("vector"), dtype=np.float32) for r in self.rows]) if self.rows else np.empty((0, self.embedder.dimensions), dtype=np.float32)
                self.keys = [duplicate_key(r) for r in self.rows]
                groups = {}
                for i, key in enumerate(self.keys):
                    groups.setdefault(key, []).append(i)
                self.copies = {k: sorted(v, key=lambda i: self.rows[i]["path"]) for k, v in groups.items() if len(v) > 1}
                self.matrix_revision = self.revision
            return self.rows, self.matrix, self.keys, self.copies

    def search(self, query: str, limit: int = 10, path_filter: str = "", mode: str = "auto", max_chars: int = 18000, asset_kind: str = "", allowed_prefixes: list[str] | None = None):
        if not query.strip() or len(query) > 2000:
            raise ValueError("Query must contain 1–2000 characters")
        if mode not in {"auto", "hybrid", "semantic", "lexical"}:
            raise ValueError("Mode must be auto, hybrid, semantic, or lexical")
        requested_mode = mode
        if mode == "auto":
            identifier = bool(re.fullmatch(r"[A-Za-z_][\w./:]*", query)) and (
                any(c in query for c in "_./:") or any(c.isupper() for c in query))
            mode = "lexical" if identifier else "semantic"
        if not 1 <= limit <= 30 or not 1000 <= max_chars <= 60000:
            raise ValueError("limit must be 1–30 and max_chars must be 1000–60000")
        if Path(path_filter).is_absolute() or ".." in Path(path_filter).parts:
            raise ValueError("path_filter must be a repository-relative prefix")
        start = time.perf_counter()
        rows, matrix, keys, copies = self._snapshot()
        candidates = [i for i, r in enumerate(rows) if r["path"].startswith(path_filter) and self._allowed(r["path"])
                      and (allowed_prefixes is None or any(r["path"].startswith(p) for p in allowed_prefixes))
                      and (not asset_kind or self.repo.kind(r["path"]) == asset_kind)]
        if not candidates:
            return {"query": query, "results": [], "elapsed_ms": round((time.perf_counter() - start) * 1000, 2), "mode": mode}
        ranked, similarities, lexical_ranks = {}, {}, {}
        degraded = None
        if mode != "lexical":
            try:
                with self.lock:
                    vector = self.query_cache.get(query)
                if vector is None:
                    kwargs = {} if self.query_task == "code" else {"task": "search"}
                    vector = self.embedder.encode([query], query=True, **kwargs)[0]
                    with self.lock:
                        if len(self.query_cache) >= 64:
                            self.query_cache.pop(next(iter(self.query_cache)))
                        self.query_cache[query] = vector
                scores = matrix @ vector
                ordered = sorted(candidates, key=lambda i: float(scores[i]), reverse=True)[:100]
                for rank, i in enumerate(ordered, 1):
                    ranked[i] = 1 / (60 + rank)
                    similarities[i] = round(float(scores[i]), 4)
            except Exception as exc:
                if mode == "semantic" and requested_mode != "auto":
                    raise
                degraded = f"Semantic search unavailable: {exc}"
                mode = "lexical"
        if mode != "semantic":
            tokens = list(dict.fromkeys(words(query).split()))
            expression = " OR ".join('"' + token + '"' for token in tokens)
            if expression:
                with self.lock:
                    # Apply project/path boundaries before the lexical candidate cap.
                    prefixes = allowed_prefixes if allowed_prefixes is not None else [""]
                    scope_sql = " OR ".join("substr(c.path, 1, ?) = ?" for _ in prefixes) or "0"
                    params = [expression, len(path_filter), path_filter]
                    for prefix in prefixes:
                        params.extend((len(prefix), prefix))
                    hits = [r[0] for r in self.db.execute(
                        "SELECT chunks_fts.id FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.id "
                        "WHERE chunks_fts MATCH ? AND substr(c.path, 1, ?) = ? AND (" + scope_sql + ") "
                        "ORDER BY bm25(chunks_fts) LIMIT 500", params)]
                lookup = {rows[i]["id"]: i for i in candidates}
                for identifier in hits:
                    if identifier in lookup:
                        i = lookup[identifier]
                        rank = len(lexical_ranks) + 1
                        lexical_ranks[i] = rank
                        ranked[i] = ranked.get(i, 0) + 1 / (60 + rank)
                        if rank >= 100:
                            break
        results, stale_paths, source_cache, shown = [], set(), {}, set()
        remaining = max_chars
        allowed = set(candidates) if copies else set()

        def current(row):
            path = row["path"]
            if path not in source_cache:
                try:
                    source = self.repo.read(path)
                    if self.repo.fingerprint(path, source) != row["file_hash"]:
                        stale_paths.add(path)
                        source_cache[path] = None
                    else:
                        source_cache[path] = source.splitlines()
                except (OSError, UnicodeError, ValueError):
                    stale_paths.add(path)
                    source_cache[path] = None
            return source_cache[path]

        for i in sorted(ranked, key=ranked.get, reverse=True):
            row = rows[i]
            path = row["path"]
            # Identical copies share one result slot; the result lists the other paths.
            if keys[i] in shown:
                continue
            lines = current(row)
            if lines is None:
                continue
            # Prefer distinct locations over duplicate file/function representations.
            if any(r["path"] == path and r["start_line"] == row["start"] and (
                row["kind"] != "block" or r["kind"] != "block" or
                row["start"] != row["end"] or r["code"] == row["text"][:4500]
            ) for r in results):
                shown.add(keys[i])  # The shown result already lists this location's copies.
                continue
            end = min(row["end"], row["start"] + 99)
            code = "\n".join(row["text"].splitlines()[:100]) if row["kind"] == "block" else "\n".join(lines[row["start"] - 1:end])
            allowance = min(4500, remaining)
            if allowance < 200:
                break
            snippet = code[:allowance]
            duplicates, omitted = [], 0
            for j in copies.get(keys[i], ()):
                if j == i or rows[j]["path"] == path or j not in allowed:
                    continue
                if len(duplicates) >= MAX_DUPLICATES:
                    omitted += 1
                elif current(rows[j]) is not None:
                    duplicates.append({"path": rows[j]["path"]})
            shown.add(keys[i])
            results.append({"id": row["id"], "path": path, "symbol": row["symbol"], "kind": row["kind"],
                            "start_line": row["start"], "end_line": row["end"], "parent_id": row["parent_id"],
                            "code": snippet, "truncated": end < row["end"] or len(snippet) < len(code),
                            "asset_kind": self.repo.kind(path),
                            "line_origin": "extracted_text" if Path(path).suffix.lower() in {".pdf", ".docx"} else "file",
                            "score": round(ranked[i], 6), "cosine": similarities.get(i), "lexical_rank": lexical_ranks.get(i),
                            "content_id": digest(repr(keys[i]))[:24], "duplicates": duplicates, "duplicates_omitted": omitted})
            remaining -= len(snippet)
            if len(results) >= limit:
                break
        return {"query": query, "mode": mode, "results": results, "stale_paths": sorted(stale_paths),
                "degraded": degraded, "elapsed_ms": round((time.perf_counter() - start) * 1000, 2)}

    def read_file(self, path: str, start_line: int = 1, max_lines: int = 120):
        if not self._allowed(path):
            raise ValueError("Path excluded from this index")
        if start_line < 1 or not 1 <= max_lines <= 300:
            raise ValueError("start_line must be positive and max_lines must be 1–300")
        source = self.repo.read(path)
        lines = source.splitlines()
        end = min(len(lines), start_line + max_lines - 1)
        return {"path": path, "start_line": start_line, "end_line": end,
                "code": "\n".join(lines[start_line - 1:end])[:24000], "total_lines": len(lines)}

    def read_symbol(self, identifier: str):
        with self.lock:
            row = self.db.execute("SELECT * FROM chunks WHERE id=?", (identifier,)).fetchone()
            if row is None:
                raise ValueError("Symbol not found; search again after indexing")
            expected = self.db.execute("SELECT hash FROM files WHERE path=?", (row["path"],)).fetchone()[0]
        source = self.repo.read(row["path"])
        if self.repo.fingerprint(row["path"], source) != expected:
            raise ValueError("Source changed since indexing. Use read_file or search again after the update.")
        lines = source.splitlines()
        end = min(row["end"], row["start"] + 299)
        code = "\n".join(row["text"].splitlines()[:300]) if row["kind"] == "block" else "\n".join(lines[row["start"] - 1:end])
        result = {"path": row["path"], "start_line": row["start"], "end_line": end,
                  "code": code[:24000], "total_lines": len(lines)}
        result.update({"id": identifier, "symbol": row["symbol"], "kind": row["kind"], "parent_id": row["parent_id"],
                       "symbol_end_line": row["end"], "truncated": row["end"] > end or len(code) > 24000})
        return result
