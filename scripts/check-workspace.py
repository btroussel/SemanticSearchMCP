#!/usr/bin/env python3
"""Real-model smoke test in disposable folders; never index user sources."""
import asyncio
import json
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import httpx
from PIL import Image, ImageDraw
from docx import Document
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

root = Path(__file__).resolve().parents[1]


async def check_mcp(url, state, source, project):
    params = StdioServerParameters(command=str(root / ".venv/bin/code-search"),
                                  args=["mcp", "--general", "--url", url, "--token-file", str(state / "access.key"), "--project", str(project)])
    async with stdio_client(params) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            tools = await session.list_tools()
            assert len(tools.tools) == 6
            listed = await session.call_tool("list_sources", {})
            assert listed.structuredContent["sources"][0]["id"] == source
            found = await session.call_tool("search_local", {"query": "authenticate_user", "source_id": source, "mode": "lexical", "asset_kind": "code"})
            assert found.structuredContent["results"][0]["symbol"] == "authenticate_user"
            picture = await session.call_tool("read_image", {"source_id": source, "path": "asset-a.png"})
            assert not picture.isError and any(c.type == "image" for c in picture.content)
            outside = await session.call_tool("read_code_file", {"source_id": source, "path": "../outside.txt"})
            assert outside.isError
    return ["6 tools", "structured search", "image pixels", "path boundary"]


def main():
    with tempfile.TemporaryDirectory(prefix="local-search-smoke-") as temporary:
        base = Path(temporary)
        folder = base / "source"; folder.mkdir()
        (folder / "auth.py").write_text('def authenticate_user(password, expected_hash):\n    """Check a password against the stored hash before granting access."""\n    return password == expected_hash\n')
        (folder / "meeting.txt").write_text("Meeting notes: the next product launch is scheduled for Monday. Marketing will prepare the announcement.")
        document = Document(); document.add_paragraph("Invoice: consulting services, total 2400 euros, payment due in November."); document.save(folder / "invoice.docx")
        image = Image.new("RGB", (512, 512), "white")
        ImageDraw.Draw(image).ellipse((90, 90, 422, 422), fill="red"); image.save(folder / "asset-a.png")
        image = Image.new("RGB", (512, 512), "white"); draw = ImageDraw.Draw(image)
        draw.line((60, 60, 60, 450, 470, 450), fill="black", width=5)
        for x, height in [(95, 140), (190, 280), (285, 220), (380, 350)]:
            draw.rectangle((x, 450-height, x+60, 447), fill="blue")
        image.save(folder / "asset-b.png")
        state = base / "state"
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
        url = f"http://127.0.0.1:{port}"
        with (base / "service.log").open("w+") as log:
            process = subprocess.Popen([str(root / ".venv/bin/code-search"), "workspace", "--model", str(root / "models/embeddinggemma-2"),
                                        "--state", str(state), "--port", str(port), "--no-watch"], stdout=log, stderr=log)
            try:
                client = httpx.Client(base_url=url, timeout=120, trust_env=False)
                deadline = time.monotonic() + 180
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError("Smoke service stopped")
                    if (state / "access.key").exists():
                        client.headers["Authorization"] = "Bearer " + (state / "access.key").read_text().strip()
                        try:
                            if client.get("/status").status_code == 200: break
                        except httpx.ConnectError: pass
                    time.sleep(0.2)
                added = client.post("/sources", json={"path": str(folder), "name": "Disposable smoke fixture"}); added.raise_for_status()
                source = added.json()["id"]
                while time.monotonic() < deadline:
                    status = client.get("/status").json()["sources"][0]
                    if status["phase"] == "error": raise RuntimeError(status["error"])
                    if status["phase"] == "ready": break
                    time.sleep(0.25)
                assert status["phase"] == "ready", status
                assert client.get("/settings").json()["max_tokens"] == 4096
                report = {"device": status["device"], "files": status["files"], "max_tokens": 4096,
                          "precision": "float32", "dimensions": 768, "image_tokens": 280, "queries": []}
                cases = [("Un cercle rouge sur un fond blanc", "images", "asset-a.png"),
                         ("Un graphique à barres bleues", "images", "asset-b.png"),
                         ("Where is the password checked before granting access?", "code", "auth.py"),
                         ("When is the consulting invoice due?", "documents", "invoice.docx")]
                for query, kind, expected in cases:
                    response = client.post("/search", json={"query": query, "source_id": source, "asset_kind": kind, "mode": "semantic"}); response.raise_for_status()
                    found = response.json(); assert not found["issues"], found
                    assert found["results"][0]["path"] == expected, found
                    report["queries"].append({"query": query, "top_path": expected, "elapsed_ms": found["elapsed_ms"], "cosine": found["results"][0]["cosine"]})
                changed = client.put("/settings", json={"max_tokens": 512})
                changed.raise_for_status()
                assert changed.json()["reindex_queued"]
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    status = client.get("/status").json()["sources"][0]
                    if status["phase"] == "error": raise RuntimeError(status["error"])
                    if status["phase"] == "ready" and status["files"] == 5: break
                    time.sleep(0.25)
                assert status["phase"] == "ready" and status["max_tokens"] == 512
                found = client.post("/search", json={"query": "Where is the password checked before granting access?",
                                                      "source_id": source, "asset_kind": "code", "mode": "semantic"})
                found.raise_for_status()
                assert found.json()["results"][0]["path"] == "auth.py", found.json()
                assert json.loads((state / "settings.json").read_text())["max_tokens"] == 512
                report["settings"] = "4096 default; live update to 512; persisted; reindexed; semantic search passed"
                report["model_options"] = []
                for dimensions, image_tokens in [(256, 70), (512, 140), (128, 560), (768, 1120)]:
                    options = {"precision": "bfloat16", "dimensions": dimensions, "image_tokens": image_tokens}
                    changed = client.put("/settings", json=options); changed.raise_for_status()
                    assert changed.json()["reindex_queued"]
                    deadline = time.monotonic() + 120
                    while time.monotonic() < deadline:
                        status = client.get("/status").json()["sources"][0]
                        if status["phase"] == "error": raise RuntimeError(status["error"])
                        if status["phase"] == "ready" and status["files"] == 5: break
                        time.sleep(0.25)
                    assert status["phase"] == "ready" and status["dimensions"] == dimensions
                    measured = []
                    for query, kind, expected in cases:
                        response = client.post("/search", json={"query": query, "source_id": source,
                                                                "asset_kind": kind, "mode": "semantic"})
                        response.raise_for_status(); found = response.json()
                        assert not found["issues"] and found["results"][0]["path"] == expected, found
                        measured.append({"query": query, "top_path": expected, "elapsed_ms": found["elapsed_ms"],
                                         "cosine": found["results"][0]["cosine"]})
                    report["model_options"].append({**options, "max_tokens": 512, "queries": measured})
                report["query_tasks"] = []
                for task in ["code", "search", "question_answering", "fact_checking"]:
                    changed = client.put("/settings", json={"query_task": task}); changed.raise_for_status()
                    assert not changed.json()["reindex_queued"]
                    found = client.post("/search", json={"query": cases[2][0], "source_id": source,
                                                        "asset_kind": "code", "mode": "semantic"})
                    found.raise_for_status()
                    assert not found.json()["issues"] and found.json()["results"][0]["path"] == "auth.py"
                    report["query_tasks"].append(task)
                report["mcp"] = asyncio.run(check_mcp(url, state, source, folder))
                assert client.delete(f"/sources/{source}").json()["access_revoked"]
                assert client.get("/image", params={"source_id": source, "path": "asset-a.png"}).status_code == 400
                report["revocation"] = "passed"
                changed = client.put("/settings", json={"images": False}); changed.raise_for_status()
                assert not client.get("/status").json()["image_search"]
                added = client.post("/sources", json={"path": str(folder), "kinds": ["code", "documents"]})
                added.raise_for_status(); text_source = added.json()["id"]
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    status = client.get("/status").json()["sources"][0]
                    if status["phase"] == "error": raise RuntimeError(status["error"])
                    if status["phase"] == "ready" and status["files"] == 3: break
                    time.sleep(0.25)
                assert status["phase"] == "ready" and status["files"] == 3
                found = client.post("/search", json={"query": cases[2][0], "source_id": text_source, "mode": "semantic"})
                found.raise_for_status()
                assert not found.json()["issues"] and found.json()["results"][0]["path"] == "auth.py"
                report["text_only"] = "BF16 text-only reload, indexing and retrieval passed"
                (root / "docs/workspace-smoke.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
                print(json.dumps(report, indent=2, ensure_ascii=False), flush=True)
                client.close()
            except Exception:
                log.flush(); log.seek(0); print(log.read()[-12000:], file=sys.stderr)
                raise
            finally:
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill(); process.wait()


if __name__ == "__main__":
    main()
