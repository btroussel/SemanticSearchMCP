import hashlib
import time
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from local_code_search.chunks import split_file
from local_code_search.files import Repository
from local_code_search.index import Index
from local_code_search.service import Worker, create_app


class FakeEmbedder:
    dimensions = 16
    fingerprint = "test-only"
    device = "cpu"
    model = True

    def __init__(self):
        self.calls = 0

    def encode(self, texts, query=False):
        self.calls += len(texts)
        vectors = np.array([list(hashlib.md5(t.encode()).digest()) for t in texts], dtype=np.float32)
        return vectors / np.linalg.norm(vectors, axis=1, keepdims=True)


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "repo"
    root.mkdir()
    (root / "tracker.py").write_text('class Tracker:\n    def associate(self, detections):\n        """Match observations to existing tracks."""\n        return detections\n')
    return root


def test_source_hierarchy_and_decorators():
    chunks = split_file("test.py", "class Tracker:\n    @staticmethod\n    def match():\n        return 1\n")
    method = next(c for c in chunks if c.symbol == "Tracker.match")
    parent = next(c for c in chunks if c.id == method.parent_id)
    assert parent.symbol == "Tracker"
    assert method.start == 2 and method.end == 4
    assert "@staticmethod" in method.text


def test_typescript_ast():
    chunks = split_file("tracker.ts", "export class Tracker {\n  match(detections: number[]) { return detections; }\n}\n")
    method = next(c for c in chunks if c.symbol == "Tracker.match")
    assert next(c for c in chunks if c.id == method.parent_id).symbol == "Tracker"


def test_incremental_cache_stale_source_and_deletion(repo, tmp_path):
    embedder = FakeEmbedder()
    index = Index(repo, tmp_path / "index.sqlite", embedder)
    initial = index.sync()
    assert initial["changed_files"] == 1
    calls = embedder.calls
    assert index.sync()["embedded_chunks"] == 0
    assert embedder.calls == calls
    result = index.search("associate", mode="lexical")
    symbol = next(r for r in result["results"] if r["symbol"] == "Tracker.associate")
    assert index.read_symbol(symbol["parent_id"])["symbol"] == "Tracker"
    file = repo / "tracker.py"
    file.write_text("# An unrelated header\n" + file.read_text())
    assert index.search("associate", mode="lexical")["stale_paths"] == ["tracker.py"]
    with pytest.raises(ValueError, match="changed"):
        index.read_symbol(symbol["id"])
    update = index.sync({"tracker.py"})
    assert update["cached_chunks"] >= 1
    assert update["embedded_chunks"] < initial["embedded_chunks"] + 1
    assert index.search("associate", mode="lexical")["results"]
    file.unlink()
    assert index.sync()["deleted_files"] == 1
    assert index.search("associate", mode="lexical")["results"] == []


def test_ignores_and_confined_reads(repo, tmp_path):
    (repo / ".gitignore").write_text("ignored/\n")
    (repo / "ignored").mkdir()
    (repo / "ignored" / "private.py").write_text("secret = 1")
    outside = tmp_path / "outside.py"
    outside.write_text("outside = 1")
    (repo / "link.py").symlink_to(outside)
    (repo / ".env").write_text("SECRET=1")
    repository = Repository(repo)
    assert set(repository.files()) == {"tracker.py"}
    for path in ["../outside.py", str(outside), "link.py", ".env", "ignored/private.py"]:
        with pytest.raises(ValueError):
            repository.read(path)


def test_source_package_named_models_is_indexed(repo):
    (repo / "models").mkdir()
    (repo / "models" / "tracker.py").write_text("def associate():\n    return 1\n")
    (repo / "models" / "weights.safetensors").write_bytes(b"not source")
    assert "models/tracker.py" in set(Repository(repo).files())
    assert "models/weights.safetensors" not in set(Repository(repo).files())


def test_config_mismatch_and_query_validation(repo, tmp_path):
    path = tmp_path / "index.sqlite"
    index = Index(repo, path, FakeEmbedder())
    with pytest.raises(ValueError, match="configuration"):
        Index(repo, path, FakeEmbedder(), ["tracker.py"])
    for query in ["", " " * 10, "a" * 2001]:
        with pytest.raises(ValueError):
            index.search(query)
    with pytest.raises(ValueError):
        index.search("associate", path_filter="../")


def test_api_returns_ranked_code_and_rejects_traversal(repo, tmp_path):
    index = Index(repo, tmp_path / "index.sqlite", FakeEmbedder())
    index.sync()
    with TestClient(create_app(index, interval=300, watch=False)) as client:
        response = client.post("/search", json={"query": "associate", "mode": "lexical"})
        assert response.status_code == 200
        assert response.json()["results"][0]["path"] == "tracker.py"
        assert client.get("/file", params={"path": "../outside.py"}).status_code == 400
        assert client.post("/search", json={"query": "x", "limit": 31}).status_code == 422
        assert client.post("/reindex").json()["queued"]
        assert client.get("/status").json()["repo"] == str(repo)


def test_saved_file_is_reindexed_by_watcher(repo, tmp_path):
    index = Index(repo, tmp_path / "index.sqlite", FakeEmbedder())
    worker = Worker(index, interval=300, watch=True)
    worker.start()
    try:
        deadline = time.monotonic() + 8
        while worker.phase != "ready" and time.monotonic() < deadline:
            time.sleep(0.05)
        assert worker.phase == "ready"
        # Allow the operating-system watcher to finish subscribing.
        time.sleep(0.3)
        file = repo / "tracker.py"
        file.write_text(file.read_text() + "\ndef newly_added_symbol():\n    return 2\n")
        while time.monotonic() < deadline:
            if index.search("newly_added_symbol", mode="lexical")["results"]:
                break
            time.sleep(0.05)
        assert any(r["symbol"] == "newly_added_symbol" for r in index.search("newly_added_symbol", mode="lexical")["results"])
    finally:
        worker.stop.set()
        worker.pending.set()
        for thread in worker.threads:
            thread.join(timeout=2)


def test_auto_selects_identifier_search_and_falls_back_on_model_failure(repo, tmp_path):
    embedder = FakeEmbedder()
    index = Index(repo, tmp_path / "index.sqlite", embedder)
    index.sync()
    assert index.search("Tracker.associate")["mode"] == "lexical"
    assert index.search("How are observations matched?")["mode"] == "semantic"

    def fail(*args, **kwargs):
        raise RuntimeError("Model unavailable")
    embedder.encode = fail
    result = index.search("Where do we associate detections?")
    assert result["mode"] == "lexical"
    assert result["degraded"] and result["results"]


def test_token_budget_rebuilds_old_index_and_preserves_long_line_tail(repo, tmp_path):
    class BoundedEmbedder(FakeEmbedder):
        max_tokens = 512

        def count_tokens(self, text):
            return len(text) + 1

        def encode(self, texts, **kwargs):
            assert all(self.count_tokens(t) <= self.max_tokens for t in texts)
            return super().encode(texts, **kwargs)

    text = "introductory background " * 600 + "UNIQUE_TAIL_MARKER"
    (repo / "paper.txt").write_text(text)
    embedder = BoundedEmbedder()
    path = tmp_path / "index.sqlite"
    index = Index(repo, path, embedder)
    index.sync()
    result = index.search("UNIQUE_TAIL_MARKER", mode="lexical")["results"]
    assert result and "UNIQUE_TAIL_MARKER" in result[0]["code"]
    assert "UNIQUE_TAIL_MARKER" in index.read_symbol(result[0]["id"])["code"]
    blocks = list(index.db.execute("SELECT text FROM chunks WHERE path='paper.txt' AND kind='block'"))
    assert any("UNIQUE_TAIL_MARKER" in row[0] for row in blocks)
    index.query_cache["stale"] = np.zeros(16)
    # Simulate an index written by the previous, unbounded chunker.
    index.db.execute("UPDATE meta SET value='3' WHERE key='chunk_version'")
    index.db.execute("DELETE FROM meta WHERE key='max_tokens'")
    index.db.commit()
    index.db.close()
    upgraded = Index(repo, path, embedder)
    assert upgraded.status()["files"] == 0
    assert upgraded.db.execute("SELECT count(*) FROM embedding_cache").fetchone()[0] == 0
    assert upgraded.sync()["changed_files"] == 2
    upgraded.db.close()
    embedder.max_tokens = 1024
    changed = Index(repo, path, embedder)
    assert changed.status()["files"] == 0
    assert changed.sync()["embedded_chunks"] > 0
    changed.db.close()
