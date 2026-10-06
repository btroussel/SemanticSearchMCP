import hashlib
import time
import threading
from pathlib import Path

import pytest

import numpy as np
from PIL import Image
from fastapi.testclient import TestClient

from semantic_search.workspace import SettingsRequest, SourceRequest, Workspace, WorkspaceSearch, create_workspace_app
from semantic_search.mcp_server import create_server


class MultimodalFixture:
    dimensions = 768
    device = "cpu"
    model = True
    images = True
    max_tokens = 4096
    precision = "float32"
    image_tokens = 280
    query_task = "auto"

    @property
    def fingerprint(self):
        return f"multimodal-test:{self.dimensions}:{self.precision}:{self.images}:{self.image_tokens}"

    def configuration(self):
        from semantic_search.settings import ModelSettings
        return {key: getattr(self, key) for key in ModelSettings.model_fields}

    def configure(self, **changes):
        for key, value in changes.items():
            if key == "max_tokens":
                self.set_max_tokens(value)
            else:
                setattr(self, key, value)

    def set_max_tokens(self, value):
        self.max_tokens = value

    def count_tokens(self, text):
        return len(text) + 1

    def encode(self, inputs, query=False, task="code"):
        rows = []
        for item in inputs:
            data = item.tobytes() if isinstance(item, Image.Image) else item.encode()
            row = np.resize(np.array(list(hashlib.md5(data).digest()), dtype=np.float32), self.dimensions)
            rows.append(row / np.linalg.norm(row))
        return np.stack(rows)


def make_workspace(tmp_path):
    return Workspace(tmp_path / "state", MultimodalFixture(), watch=False)


def test_sources_are_opt_in_scoped_and_survive_restart(tmp_path):
    workspace = make_workspace(tmp_path)
    assert workspace.status()["sources"] == []
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir(); b.mkdir()
    (a / "notes.txt").write_text("meeting notes")
    (a / "implementation.py").write_text("def authentication():\n    return True\n")
    (a / "private.txt").write_text("secret meeting notes")
    (b / "notes.txt").write_text("unrelated budget report")
    first = workspace.add(SourceRequest(path=str(a), kinds=["documents"], excludes=["private.txt"]))
    second = workspace.add(SourceRequest(path=str(b), kinds=["documents"]))
    workspace.index(first["id"]).sync(); workspace.index(second["id"]).sync()
    result = workspace.search(WorkspaceSearch(query="meeting", source_id=first["id"], mode="lexical"))
    assert {r["source_id"] for r in result["results"]} == {first["id"]}
    assert {r["path"] for r in result["results"]} == {"notes.txt"}
    restored = make_workspace(tmp_path)
    assert {s["id"] for s in restored.status()["sources"]} == {first["id"], second["id"]}
    assert restored.index(first["id"]).status()["files"] == 1


def test_authenticated_api_rejects_unauthorized_reads_and_revocation(tmp_path):
    workspace = make_workspace(tmp_path)
    root = tmp_path / "files"; root.mkdir()
    (root / "notes.txt").write_text("project notes")
    (root / "code.py").write_text("print('code')")
    (root / "excluded.txt").write_text("not authorized")
    headers = {"Authorization": f"Bearer {workspace.token}"}
    with TestClient(create_workspace_app(workspace)) as client:
        assert client.get("/status").status_code == 401
        assert client.post("/sources", json={"path": str(root)}).status_code == 401
        assert client.get("/status", headers={**headers, "Host": "evil.example"}).status_code == 403
        source = client.post("/sources", headers=headers, json={"path": str(root), "kinds": ["documents"], "excludes": ["excluded.txt"]}).json()
        sid = source["id"]
        index = workspace.index(sid)
        index.sync()
        for path in ("code.py", "excluded.txt", "../notes.txt"):
            assert client.get("/file", headers=headers, params={"source_id": sid, "path": path}).status_code == 400
        assert client.get("/file", headers=headers, params={"source_id": sid, "path": "notes.txt"}).json()["code"] == "project notes"
        removed = client.delete(f"/sources/{sid}", headers=headers).json()
        assert removed["access_revoked"]
        assert client.get("/file", headers=headers, params={"source_id": sid, "path": "notes.txt"}).status_code == 400
        assert client.post("/search", headers=headers, json={"source_id": sid, "query": "notes"}).status_code == 400
        deadline = time.monotonic() + 3
        while (workspace.state / f"{sid}.sqlite").exists() and time.monotonic() < deadline:
            time.sleep(0.03)
        assert not (workspace.state / f"{sid}.sqlite").exists()
        assert (root / "notes.txt").read_text() == "project notes"
        assert make_workspace(tmp_path).status()["sources"] == []


def test_image_content_changes_invalidate_vectors_and_type_filter(tmp_path):
    workspace = make_workspace(tmp_path)
    root = tmp_path / "images"; root.mkdir()
    picture = root / "picture.png"
    Image.new("RGB", (40, 40), "red").save(picture)
    (root / "notes.txt").write_text("picture description")
    source = workspace.add(SourceRequest(path=str(root)))
    index = workspace.index(source["id"])
    initial = index.sync()
    assert initial["changed_files"] == 2
    found = workspace.search(WorkspaceSearch(query="picture", mode="lexical", asset_kind="images"))
    assert found["results"] and all(r["asset_kind"] == "images" for r in found["results"])
    Image.new("RGB", (40, 40), "blue").save(picture)
    assert index.search("picture", mode="lexical", asset_kind="images")["stale_paths"] == ["picture.png"]
    assert index.sync()["embedded_chunks"] == 1
    assert workspace.thumbnail(source["id"], "picture.png").startswith(b"\x89PNG")


def test_pdf_docx_extracted_text_is_searchable_and_labeled(tmp_path):
    from docx import Document
    from pypdf import PdfWriter
    from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject
    workspace = make_workspace(tmp_path)
    root = tmp_path / "documents"; root.mkdir()
    doc = Document(); doc.add_paragraph("Quarterly finance forecast"); doc.save(root / "report.docx")
    writer = PdfWriter(); page = writer.add_blank_page(width=200, height=200)
    font = DictionaryObject({NameObject("/Type"): NameObject("/Font"), NameObject("/Subtype"): NameObject("/Type1"), NameObject("/BaseFont"): NameObject("/Helvetica")})
    page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): writer._add_object(font)})})
    stream = DecodedStreamObject(); stream.set_data(b"BT /F1 12 Tf 10 100 Td (Annual finance report) Tj ET")
    page[NameObject("/Contents")] = writer._add_object(stream)
    writer.write(root / "annual.pdf")
    source = workspace.add(SourceRequest(path=str(root), kinds=["documents"]))
    index = workspace.index(source["id"]); index.sync()
    results = index.search("finance", mode="lexical")["results"]
    assert {r["path"] for r in results} == {"report.docx", "annual.pdf"}
    assert all(r["line_origin"] == "extracted_text" for r in results)


def test_general_mcp_has_image_and_source_tools_but_no_folder_authorization(tmp_path):
    workspace = make_workspace(tmp_path)
    server = create_server("http://127.0.0.1:8766", workspace.state / "access.key", general=True)
    import asyncio
    names = {t.name for t in asyncio.run(server.list_tools())}
    assert {"list_sources", "search_local", "search_code", "read_image", "read_symbol"} <= names
    assert "add_source" not in names and "remove_source" not in names
    # list_sources reports readiness, so general mode has no separate index_status tool.
    assert "index_status" not in names


def test_mcp_schemas_expose_service_bounds_and_hide_source_id_in_single_repository_mode():
    import asyncio
    general = {t.name: t.inputSchema["properties"] for t in asyncio.run(
        create_server("http://127.0.0.1:8766", general=True, project=Path.cwd()).list_tools())}
    assert general["search_local"]["mode"]["enum"] == ["auto", "hybrid", "semantic", "lexical"]
    assert general["search_local"]["asset_kind"]["enum"] == ["", "code", "documents", "images"]
    assert general["search_code"]["response_format"]["enum"] == ["concise", "detailed"]
    assert (general["search_code"]["limit"]["minimum"], general["search_code"]["limit"]["maximum"]) == (1, 30)
    assert general["read_code_file"]["max_lines"]["maximum"] == 300
    single = {t.name: t.inputSchema["properties"] for t in asyncio.run(create_server("http://127.0.0.1:8765").list_tools())}
    assert set(single) == {"search_code", "read_symbol", "read_code_file", "index_status", "refresh_index"}
    assert all("source_id" not in properties for properties in single.values())


def test_revocation_during_embedding_prevents_publication_and_cleans_cache(tmp_path):
    entered, release = threading.Event(), threading.Event()

    class SlowEmbedder(MultimodalFixture):
        def encode(self, inputs, **kwargs):
            entered.set()
            assert release.wait(5)
            return super().encode(inputs, **kwargs)

    root = tmp_path / "files"; root.mkdir()
    (root / "notes.txt").write_text("private project notes")
    workspace = Workspace(tmp_path / "state", SlowEmbedder(), watch=False)
    workspace.start()
    try:
        source = workspace.add(SourceRequest(path=str(root), kinds=["documents"]))
        assert entered.wait(3)
        before = time.monotonic()
        assert workspace.remove(source["id"])["access_revoked"]
        assert time.monotonic() - before < 1
        with pytest.raises(ValueError, match="not authorized"):
            workspace.index(source["id"])
        release.set()
        deadline = time.monotonic() + 3
        while (workspace.state / f"{source['id']}.sqlite").exists() and time.monotonic() < deadline:
            time.sleep(0.03)
        assert not (workspace.state / f"{source['id']}.sqlite").exists()
        assert not workspace.retired
    finally:
        release.set()
        workspace.stop()


def test_restart_finishes_cache_cleanup_for_revoked_sources(tmp_path):
    workspace = make_workspace(tmp_path)
    orphan = workspace.state / ("a" * 32 + ".sqlite")
    orphan.write_bytes(b"interrupted cleanup fixture")
    unrelated = workspace.state / "unrelated.sqlite"
    unrelated.write_bytes(b"leave unrelated files alone")
    make_workspace(tmp_path)
    assert not orphan.exists()
    assert unrelated.exists()


def test_settings_are_authenticated_validated_persisted_and_rebuild_vectors(tmp_path):
    workspace = make_workspace(tmp_path)
    root = tmp_path / "documents"; root.mkdir()
    (root / "paper.txt").write_text("Research findings and experimental results.\n" * 50)
    source = workspace.add(SourceRequest(path=str(root), kinds=["documents"]))
    index = workspace.index(source["id"])
    index.sync()
    old_chunks = index.status()["chunks"]
    index.query_cache["old query"] = np.zeros(16)
    # No lifespan here: assertions inspect caches before background indexing runs.
    client = TestClient(create_workspace_app(workspace))
    headers = {"Authorization": f"Bearer {workspace.token}"}
    assert client.get("/settings").status_code == 401
    assert client.put("/settings", json={"max_tokens": 512}).status_code == 401
    assert client.get("/settings", headers=headers).json()["max_tokens"] == 4096
    for value in [0, 255, 8193, True, 4096.0, "512"]:
        assert client.put("/settings", headers=headers, json={"max_tokens": value}).status_code == 422
    same = client.put("/settings", headers=headers, json={"max_tokens": 4096}).json()
    assert not same["reindex_queued"] and index.status()["chunks"] == old_chunks
    reply = client.put("/settings", headers=headers, json={"max_tokens": 512})
    assert reply.status_code == 200 and reply.json()["reindex_queued"]
    assert not index.query_cache and index.status()["files"] == 0
    assert index.db.execute("SELECT count(*) FROM embedding_cache").fetchone()[0] == 0
    assert index.sync()["embedded_chunks"] > 0
    assert index.status()["chunks"] > old_chunks
    assert workspace.status()["max_tokens"] == 512
    index.db.close()
    restored = make_workspace(tmp_path)
    assert restored.embedder.max_tokens == 512
    assert restored.index(source["id"]).status()["files"] == 1
    restored.index(source["id"]).db.close()
    overridden = Workspace(workspace.state, MultimodalFixture(), watch=False, max_tokens=1024)
    assert overridden.status()["max_tokens"] == 1024
    assert overridden.index(source["id"]).status()["files"] == 0
    overridden.index(source["id"]).db.close()
    client.close()


def test_setting_change_cancels_inflight_indexing_before_rebuilding(tmp_path):
    entered, release = threading.Event(), threading.Event()

    class SlowEmbedder(MultimodalFixture):
        def __init__(self):
            self.limits = []

        def encode(self, inputs, **kwargs):
            self.limits.append(self.max_tokens)
            if len(self.limits) == 1:
                entered.set()
                assert release.wait(5)
            assert all(self.count_tokens(t) <= self.max_tokens for t in inputs)
            return super().encode(inputs, **kwargs)

    root = tmp_path / "documents"; root.mkdir()
    (root / "paper.txt").write_text("Experimental methods and analysis.\n" * 60)
    workspace = Workspace(tmp_path / "state", SlowEmbedder(), watch=False)
    source = workspace.add(SourceRequest(path=str(root), kinds=["documents"]))
    worker = workspace.sources[source["id"]]["worker"]
    result = []
    update = threading.Thread(target=lambda: result.append(workspace.update_settings(
        SettingsRequest(max_tokens=512, dimensions=256, precision="bfloat16"))))
    workspace.start()
    try:
        assert entered.wait(3)
        update.start()
        assert worker.reset_requested.wait(3)
        release.set()
        update.join(timeout=5)
        assert not update.is_alive() and result[0]["max_tokens"] == 512
        deadline = time.monotonic() + 3
        while (worker.phase != "ready" or worker.index.status()["files"] != 1) and time.monotonic() < deadline:
            time.sleep(0.03)
        assert worker.phase == "ready" and worker.index.status()["files"] == 1
        assert worker.index._snapshot()[1].shape[1] == 256
        assert workspace.embedder.precision == "bfloat16"
        assert workspace.embedder.limits[0] == 4096
        assert all(limit == 512 for limit in workspace.embedder.limits[1:])
        assert not worker.reset_requested.is_set()
    finally:
        release.set()
        if update.is_alive():
            update.join(timeout=5)
        workspace.stop()


def test_model_settings_partial_updates_invalidate_vectors_and_survive_restart(tmp_path):
    import json
    workspace = make_workspace(tmp_path)
    root = tmp_path / 'code'; root.mkdir()
    (root / 'a.py').write_text('def authenticate():\n    return True\n')
    source = workspace.add(SourceRequest(path=str(root), kinds=['code']))
    index = workspace.index(source['id'])
    index.sync()
    index.search('where is authentication implemented', mode='semantic')
    client = TestClient(create_workspace_app(workspace))
    headers = {'Authorization': f'Bearer {workspace.token}'}
    reply = client.put('/settings', headers=headers, json={'precision': 'bfloat16', 'dimensions': 256, 'image_tokens': 70})
    assert reply.status_code == 200 and reply.json()['reindex_queued']
    assert reply.json()['max_tokens'] == 4096  # Omitted values are preserved.
    assert index.status()['files'] == 0 and not index.query_cache
    assert index.db.execute('SELECT count(*) FROM embedding_cache').fetchone()[0] == 0
    assert index.sync()['embedded_chunks'] > 0
    assert len(index._snapshot()[1][0]) == 256
    chunks = index.status()['chunks']
    index.query_cache['previous'] = np.zeros(256)
    task = client.put('/settings', headers=headers, json={'query_task': 'question_answering'}).json()
    assert not task['reindex_queued']
    assert index.status()['chunks'] == chunks and not index.query_cache
    settings = client.get('/settings', headers=headers).json()
    assert settings['image_encoder_available']
    assert json.loads(workspace.settings_path.read_text())['precision'] == 'bfloat16'
    assert workspace.settings_path.stat().st_mode & 0o777 == 0o600
    index.db.close()
    restored = make_workspace(tmp_path)
    assert restored.embedder.configuration() == workspace.embedder.configuration()
    assert restored.index(source['id']).status()['files'] == 1
    restored.index(source['id']).db.close()


@pytest.mark.parametrize('changes', [
    {'precision': 'float16'}, {'dimensions': 999}, {'dimensions': 256.0},
    {'images': 'false'}, {'image_tokens': 300}, {'query_task': 'clustering'},
    {'max_tokens': None}, {'unknown_option': True},
])
def test_invalid_settings_do_not_persist(tmp_path, changes):
    workspace = make_workspace(tmp_path)
    client = TestClient(create_workspace_app(workspace))
    before = workspace.embedder.configuration()
    reply = client.put('/settings', headers={'Authorization': f'Bearer {workspace.token}'}, json=changes)
    assert reply.status_code == 422
    assert workspace.embedder.configuration() == before and not workspace.settings_path.exists()


def test_image_encoder_settings_preserve_authorization_and_text_only_restriction(tmp_path):
    workspace = make_workspace(tmp_path)
    root = tmp_path / 'pictures'; root.mkdir()
    source = workspace.add(SourceRequest(path=str(root), kinds=['images']))
    with pytest.raises(ValueError, match='Remove sources'):
        workspace.update_settings(SettingsRequest(images=False))
    assert workspace.embedder.images and source['id'] in workspace.sources
    workspace.remove(source['id'])
    workspace.update_settings(SettingsRequest(images=False))
    assert not workspace.embedder.images
    with pytest.raises(ValueError, match='image encoder'):
        workspace.add(SourceRequest(path=str(root), kinds=['images']))
    workspace.update_settings(SettingsRequest(images=True))
    text = MultimodalFixture(); text.images = False
    restricted = Workspace(tmp_path / 'text-only', text, watch=False)
    assert not restricted.settings()['image_encoder_available']
    with pytest.raises(ValueError, match='--text-only'):
        restricted.update_settings(SettingsRequest(images=True))


def test_restart_recovers_interrupted_model_settings_rebuild(tmp_path):
    import json
    workspace = make_workspace(tmp_path)
    root = tmp_path / 'code'; root.mkdir()
    (root / 'a.py').write_text('def authenticate():\n    return True\n')
    source = workspace.add(SourceRequest(path=str(root), kinds=['code']))
    index = workspace.index(source['id']); index.sync(); index.db.close()
    # Simulate stopping after the settings rename, before any index was reset.
    workspace.settings_path.write_text(json.dumps({'dimensions': 128, 'precision': 'bfloat16'}))
    restored = make_workspace(tmp_path)
    index = restored.index(source['id'])
    assert source['id'] in restored.sources and index.status()['files'] == 0
    assert index.sync()['embedded_chunks'] > 0
    assert index._snapshot()[1].shape[1] == 128
    index.db.close()


def test_failed_settings_write_keeps_runtime_and_index_usable(tmp_path, monkeypatch):
    from pathlib import Path
    workspace = make_workspace(tmp_path)
    root = tmp_path / 'code'; root.mkdir()
    (root / 'a.py').write_text('def authenticate():\n    return True\n')
    source = workspace.add(SourceRequest(path=str(root), kinds=['code']))
    worker = workspace.sources[source['id']]['worker']; worker.index.sync()
    before = workspace.embedder.configuration()
    original = Path.replace

    def fail_settings(path, target):
        if target == workspace.settings_path:
            raise OSError('disk write failed')
        return original(path, target)

    monkeypatch.setattr(Path, 'replace', fail_settings)
    with pytest.raises(OSError, match='disk write failed'):
        workspace.update_settings(SettingsRequest(dimensions=256))
    assert workspace.embedder.configuration() == before
    assert worker.index.status()['files'] == 1 and not worker.reset_requested.is_set()
    assert worker.index.search('authenticate', mode='lexical')['results']


def test_identical_files_across_sources_share_one_result(tmp_path):
    workspace = make_workspace(tmp_path)
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir(); b.mkdir()
    for root in (a, b):
        (root / "report.txt").write_text("annual meeting minutes")
    (a / "report copy.txt").write_text("annual meeting minutes")
    (b / "agenda.txt").write_text("meeting agenda draft")
    first = workspace.add(SourceRequest(path=str(a), kinds=["documents"]))
    second = workspace.add(SourceRequest(path=str(b), kinds=["documents"]))
    workspace.index(first["id"]).sync(); workspace.index(second["id"]).sync()
    results = workspace.search(WorkspaceSearch(query="meeting", mode="lexical"))["results"]
    assert len(results) == 2
    report = next(r for r in results if r["path"] != "agenda.txt")
    locations = {(report["source_id"], report["path"])} | {(d["source_id"], d["path"]) for d in report["duplicates"]}
    assert locations == {(first["id"], "report.txt"), (first["id"], "report copy.txt"), (second["id"], "report.txt")}
