import asyncio
import json
import socket
import threading
import time
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from semantic_search.mcp_server import create_server
from semantic_search.workspace import SourceRequest, Workspace
from test_workspace import MultimodalFixture


class AccessEmbedder(MultimodalFixture):
    def configuration(self):
        from semantic_search.settings import ModelSettings
        return {**ModelSettings().model_dump(), "dimensions": self.dimensions,
                "images": self.images, "max_tokens": self.max_tokens}


@pytest.fixture
def scoped(tmp_path):
    workspace = Workspace(tmp_path / "state", AccessEmbedder(), watch=False)
    code = tmp_path / "code"
    project, sibling = code / "project", code / "project-other"
    papers = tmp_path / "papers"
    for path in (project, sibling, papers):
        path.mkdir(parents=True)
        (path / "auth.py").write_text("class Login:\n    def authenticate_user(self):\n        return True\n")
        Image.new("RGB", (20, 20), "red").save(path / "image.png")
    (papers / "private").mkdir()
    (papers / "private" / "auth.py").write_text("private_authentication = True")
    source = workspace.add(SourceRequest(path=str(code)))
    extra = workspace.add(SourceRequest(path=str(papers)))
    for sid in (source["id"], extra["id"]):
        workspace.index(sid).sync()
    client = TestClient(create_app(workspace))
    app_headers = {"Authorization": f"Bearer {workspace.token}"}
    mcp_headers = {**app_headers, "X-Local-Search-Project": project.as_uri()}
    yield workspace, client, project, sibling, papers, source, extra, app_headers, mcp_headers
    client.close()
    for entry in workspace.sources.values():
        entry["worker"].index.db.close()


def create_app(workspace):
    from semantic_search.workspace import create_workspace_app
    return create_workspace_app(workspace)


def test_project_scope_filters_search_status_and_all_read_tools(scoped):
    workspace, client, project, sibling, papers, source, extra, app_headers, headers = scoped
    sid = source["id"]
    status = client.get("/status", headers=headers)
    assert status.headers["X-Local-Search-Scoped"] == "1"
    data = status.json()
    assert data["project"] == str(project) and data["default_scope"] == "project"
    assert len(data["sources"]) == 1 and data["files"] == 2
    assert data["sources"][0]["last_sync"] is None
    assert data["sources"][0]["allowed_paths"] == [{"path_prefix": "project/", "role": "project"}]
    for mode in ("lexical", "semantic", "hybrid", "auto"):
        reply = client.post("/search", headers=headers, json={"query": "authenticate_user", "mode": mode}).json()
        assert reply["results"] and all(r["path"].startswith("project/") for r in reply["results"])
    for path in ("project-other/auth.py", "project/../project-other/auth.py", "../outside.py"):
        assert client.get("/file", headers=headers, params={"source_id": sid, "path": path}).status_code == 400
    assert client.get("/file", headers=headers, params={"source_id": sid, "path": "project/auth.py"}).status_code == 200
    assert client.get("/image", headers=headers, params={"source_id": sid, "path": "project-other/image.png"}).status_code == 400
    assert client.get("/image", headers=headers, params={"source_id": sid, "path": "project/image.png"}).status_code == 200
    row = workspace.index(sid).db.execute("SELECT id FROM chunks WHERE path='project-other/auth.py' LIMIT 1").fetchone()
    assert client.get(f"/symbol/{row[0]}", headers=headers, params={"source_id": sid}).status_code == 400
    row = workspace.index(sid).db.execute("SELECT id FROM chunks WHERE path='project/auth.py' LIMIT 1").fetchone()
    assert client.get(f"/symbol/{row[0]}", headers=headers, params={"source_id": sid}).status_code == 200
    assert client.post("/search", headers=headers, json={"query": "authenticate_user", "source_id": extra["id"]}).status_code == 400
    assert client.post("/reindex", headers=headers, params={"source_id": extra["id"]}).status_code == 400
    # The app keeps its all-sources search experience.
    assert len(client.get("/sources", headers=app_headers).json()["sources"]) == 2


def test_additional_grants_are_per_project_explicit_persistent_and_revocable(scoped):
    workspace, client, project, sibling, papers, source, extra, app_headers, headers = scoped
    grant = {"project": str(project), "folders": [str(papers)]}
    assert client.put("/mcp-access", headers=headers, json=grant).status_code == 403
    assert client.put("/mcp-access", json=grant).status_code == 401
    assert client.put("/mcp-access", headers=app_headers, json=grant).status_code == 200
    assert json.loads(workspace.access.path.read_text()) == {str(project): [str(papers)]}
    assert workspace.access.path.stat().st_mode & 0o777 == 0o600
    assert len(client.get("/sources", headers=headers).json()["sources"]) == 2
    default = client.post("/search", headers=headers, json={"query": "authenticate_user", "mode": "lexical"}).json()
    assert {r["source_id"] for r in default["results"]} == {source["id"]}
    explicit = client.post("/search", headers=headers, json={"query": "authenticate_user", "source_id": extra["id"], "mode": "lexical"})
    assert explicit.status_code == 200 and explicit.json()["results"]
    other_headers = {**app_headers, "X-Local-Search-Project": sibling.as_uri()}
    assert client.post("/search", headers=other_headers, json={"query": "authenticate_user", "source_id": extra["id"]}).status_code == 400
    from semantic_search.access import ProjectAccess
    assert ProjectAccess(workspace.state).get(str(project))["folders"] == [str(papers)]
    assert client.put("/mcp-access", headers=app_headers, json={"project": str(project), "folders": []}).status_code == 200
    assert client.get("/file", headers=headers, params={"source_id": extra["id"], "path": "auth.py"}).status_code == 400
    assert len(client.get("/sources", headers=headers).json()["sources"]) == 1


def test_grant_can_be_a_subfolder_of_a_shared_source(scoped):
    workspace, client, project, sibling, papers, source, extra, app_headers, headers = scoped
    grant = {"project": str(project), "folders": [str(papers / "private")]}
    assert client.put("/mcp-access", headers=app_headers, json=grant).status_code == 200
    assert client.get("/file", headers=headers, params={"source_id": extra["id"], "path": "private/auth.py"}).status_code == 200
    assert client.get("/file", headers=headers, params={"source_id": extra["id"], "path": "auth.py"}).status_code == 400
    assert client.get("/image", headers=headers, params={"source_id": extra["id"], "path": "image.png"}).status_code == 400
    assert client.delete(f"/sources/{extra['id']}", headers=app_headers).status_code == 200
    assert workspace.access.get(str(project))["folders"] == []


def test_unknown_project_is_empty_and_grants_do_not_authorize_unindexed_folders(scoped, tmp_path):
    workspace, client, project, sibling, papers, source, extra, app_headers, headers = scoped
    unknown = tmp_path / "unindexed"; unknown.mkdir()
    missing_headers = {**app_headers, "X-Local-Search-Project": unknown.as_uri()}
    assert client.get("/sources", headers=missing_headers).json()["sources"] == []
    assert client.post("/search", headers=missing_headers, json={"query": "auth"}).json()["results"] == []
    assert client.put("/mcp-access", headers=app_headers, json={"project": str(project), "folders": [str(unknown)]}).status_code == 400
    for value in ("", "https://example.com/project", "file://remote/project", "file:///missing-folder"):
        assert client.get("/sources", headers={**app_headers, "X-Local-Search-Project": value}).status_code == 400
    # A bridge cannot change settings, sources, or its permissions through scoped requests.
    assert client.post("/sources", headers=headers, json={"path": str(unknown)}).status_code == 403
    assert client.put("/settings", headers=headers, json={"max_tokens": 512}).status_code == 403


def test_lexical_candidate_cap_does_not_hide_project_behind_sibling_matches(scoped):
    workspace, client, project, sibling, papers, source, extra, app_headers, headers = scoped
    index = workspace.index(source["id"])
    # More sibling matches than the lexical retrieval cap, with stronger BM25 scores.
    for number in range(510):
        (sibling / f"file{number}.txt").write_text("needle")
    (project / "target.txt").write_text("needle " + "other " * 100)
    index.sync()
    found = client.post("/search", headers=headers, json={"query": "needle", "mode": "lexical"}).json()
    assert any(r["path"] == "project/target.txt" for r in found["results"])


def test_mcp_bridge_binds_launch_project_and_rejects_old_unscoped_service(scoped, monkeypatch):
    workspace, client, project, sibling, papers, source, extra, app_headers, headers = scoped
    monkeypatch.setattr("semantic_search.mcp_server.httpx.Client", lambda **kwargs: client)
    monkeypatch.chdir(project)
    server = create_server("http://127.0.0.1:8766", workspace.state / "access.key", general=True)
    async def exercise():
        listed = await server.call_tool("list_sources", {})
        assert listed[1]["project"] == str(project)
        found = await server.call_tool("search_code", {"query": "authenticate_user", "mode": "lexical"})
        assert all(r["path"].startswith("project/") for r in found[1]["results"])
        with pytest.raises(Exception, match="outside this MCP project"):
            await server.call_tool("read_image", {"source_id": source["id"], "path": "project-other/image.png"})
    asyncio.run(exercise())
    class OldClient:
        def request(self, *args, **kwargs):
            return httpx.Response(200, json={"sources": []}, request=httpx.Request("GET", "http://127.0.0.1/sources"))
    monkeypatch.setattr("semantic_search.mcp_server.httpx.Client", lambda **kwargs: OldClient())
    old = create_server("http://127.0.0.1:8766", general=True, project=project)
    with pytest.raises(Exception, match="Restart the Local Search"):
        asyncio.run(old.call_tool("list_sources", {}))


def test_stdio_session_uses_project_and_observes_live_grants(scoped):
    import uvicorn
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    workspace, client, project, sibling, papers, source, extra, app_headers, headers = scoped
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    url = f"http://127.0.0.1:{sock.getsockname()[1]}"
    backend = uvicorn.Server(uvicorn.Config(create_app(workspace), log_level="error"))
    thread = threading.Thread(target=lambda: backend.run(sockets=[sock]), daemon=True)
    thread.start()
    deadline = time.monotonic() + 5
    while not backend.started and thread.is_alive() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert backend.started
    executable = Path(__file__).resolve().parents[1] / ".venv/bin/code-search"
    params = StdioServerParameters(command=str(executable), cwd=str(project),
                                  args=["mcp", "--general", "--url", url,
                                        "--token-file", str(workspace.state / "access.key")])

    async def exercise():
        async with stdio_client(params) as (reader, writer):
            async with ClientSession(reader, writer) as session:
                await session.initialize()
                tools = await session.list_tools()
                assert len(tools.tools) == 8
                assert all("project" not in t.inputSchema["properties"] for t in tools.tools)
                listed = await session.call_tool("list_sources", {})
                assert listed.structuredContent["project"] == str(project)
                denied = await session.call_tool("read_code_file", {"source_id": extra["id"], "path": "auth.py"})
                assert denied.isError
                assert client.put("/mcp-access", headers=app_headers,
                                  json={"project": str(project), "folders": [str(papers)]}).status_code == 200
                allowed = await session.call_tool("read_code_file", {"source_id": extra["id"], "path": "auth.py"})
                assert not allowed.isError and "authenticate_user" in allowed.structuredContent["code"]
                found = await session.call_tool("search_code", {"query": "authenticate_user", "mode": "lexical"})
                assert {r["source_id"] for r in found.structuredContent["results"]} == {source["id"]}
                image = await session.call_tool("read_image", {"source_id": source["id"], "path": "project/image.png"})
                assert not image.isError and any(c.type == "image" for c in image.content)
                client.put("/mcp-access", headers=app_headers, json={"project": str(project), "folders": []})
                revoked = await session.call_tool("read_image", {"source_id": extra["id"], "path": "image.png"})
                assert revoked.isError
    try:
        asyncio.run(exercise())
    finally:
        backend.should_exit = True
        thread.join(timeout=10)
        sock.close()
        assert not thread.is_alive()
