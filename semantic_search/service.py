"""One warm embedding runtime, background updates, and a loopback REST API."""
from __future__ import annotations

import logging
import threading
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from .index import Index

log = logging.getLogger(__name__)


class Cancellation:
    def __init__(self, *events):
        self.events = events

    def is_set(self):
        return any(event.is_set() for event in self.events)


class Worker:
    def __init__(self, index: Index, interval: float = 300, watch: bool = True):
        self.index = index
        self.interval = interval
        self.watch = watch
        self.stop = threading.Event()
        self.reset_requested = threading.Event()
        self.pending = threading.Event()
        self.pending.set()
        self.phase = "starting"
        self.error = None
        self.last_success = None
        self.change_lock = threading.Lock()
        self.changed = set()
        self.full_sync = True
        self.threads = []

    def request(self, changed=None):
        with self.change_lock:
            if changed is None:
                self.full_sync = True
            else:
                self.changed.update(changed)
        self.pending.set()

    def start(self):
        for function in ([self._run, self._watch] if self.watch else [self._run]):
            thread = threading.Thread(target=function, daemon=True)
            self.threads.append(thread)
            thread.start()

    def _run(self):
        while not self.stop.is_set():
            triggered = self.pending.wait(self.interval)
            if self.stop.is_set():
                break
            with self.change_lock:
                self.pending.clear()
                changed = None if self.full_sync or not triggered else self.changed.copy()
                self.changed.clear()
                self.full_sync = False
            self.phase = "indexing"
            try:
                stats = self.index.sync(changed, cancel=Cancellation(self.stop, self.reset_requested))
                # Warm the model and query path even when the persisted index is current.
                if self.index.embedder.model is None and not self.stop.is_set() and not self.reset_requested.is_set():
                    self.index.embedder.encode(["find an implementation"], query=True)
                self.phase, self.error = "indexing" if self.reset_requested.is_set() else "ready", None
                self.last_success = time.time()
                log.info("Index update: %s", stats)
            except Exception as exc:
                self.phase, self.error = "error", str(exc)
                log.exception("Index update failed")

    def _watch(self):
        from watchfiles import watch, DefaultFilter
        from .files import EXCLUDED
        try:
            for changes in watch(self.index.repo.root, stop_event=self.stop,
                                 watch_filter=DefaultFilter(ignore_dirs=tuple(EXCLUDED)),
                                 debounce=2000, step=500):
                paths = set()
                full = False
                for _, name in changes:
                    from pathlib import Path
                    relative = Path(name).relative_to(self.index.repo.root)
                    full |= relative.name in {".gitignore", ".code-searchignore", ".cursorignore"} or Path(name).is_dir()
                    paths.add(relative.as_posix())
                if full:
                    self.request()
                else:
                    self.request(paths)
        except Exception:
            log.exception("File watching stopped; periodic reconciliation remains active")

    def status(self):
        return {**self.index.status(), "phase": self.phase, "error": self.error,
                "last_success": self.last_success, "reconcile_seconds": self.interval,
                "watch_enabled": self.watch}


class SearchRequest(BaseModel):
    query: str = Field(min_length=1, max_length=2000)
    limit: int = Field(default=10, ge=1, le=30)
    path_filter: str = ""
    mode: str = "auto"
    max_chars: int = Field(default=18000, ge=1000, le=60000)


def create_app(index: Index, interval: float = 300, watch: bool = True):
    worker = Worker(index, interval, watch)

    @asynccontextmanager
    async def lifespan(app):
        worker.start()
        yield
        worker.stop.set()
        worker.pending.set()

    app = FastAPI(title="Local code search", lifespan=lifespan)
    app.state.worker = worker

    # Blocking handlers run in FastAPI's thread pool; indexing never blocks /status.
    @app.get("/status")
    def status():
        return worker.status()

    @app.post("/search")
    def search(request: SearchRequest):
        try:
            result = index.search(**request.model_dump())
            result["index_phase"] = worker.phase
            return result
        except ValueError as exc:
            raise HTTPException(400, str(exc)) from exc

    @app.get("/symbol/{identifier}")
    def symbol(identifier: str):
        try:
            return index.read_symbol(identifier)
        except (ValueError, OSError, UnicodeError) as exc:
            raise HTTPException(409, str(exc)) from exc

    @app.get("/file")
    def read_file(path: str, start_line: int = 1, max_lines: int = 120):
        try:
            return index.read_file(path, start_line, max_lines)
        except (ValueError, OSError, UnicodeError) as exc:
            raise HTTPException(400, str(exc)) from exc

    @app.post("/reindex")
    def reindex():
        worker.request()
        return {"queued": True, "phase": worker.phase}

    return app
