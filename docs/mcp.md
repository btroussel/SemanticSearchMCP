# MCP and HTTP API

The service listens on `127.0.0.1:8766` and requires a private bearer key (`access.key`). The MCP server is a small stdio bridge that forwards requests to it; the model runs only in the service.

## Connecting

Copy the commands from **Connect an assistant** in the app (or the [README](../README.md#install)), then start a new assistant session and check `/mcp`. References: [Claude Code MCP](https://code.claude.com/docs/en/mcp), [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

The server tells the assistant when to use its tools: for what grep cannot reach (PDF, DOCX and image contents, granted folders, questions worded differently from the source) and to get oriented in unfamiliar code. For known names and complete reference lists it points the assistant to grep. To make it reach for the tools more often, add a line to the project's `AGENTS.md` or `CLAUDE.md`, such as: *Use the local-search MCP for documents, images and natural-language questions; use grep for exact identifiers.*

## Project access

The bridge is bound to the project it is launched from, or to `--project /absolute/path`. By default it can only search and read that project, and only if the project is inside a folder indexed by the app. `list_sources` reports the project so the assistant can check it matches its workspace.

To give a project access to other folders, open **Connect an assistant → Project access**, add them and save. Grants apply to that project only and can be removed at any time. Indexing a folder does not grant assistants access to it, and assistants cannot add folders or grants themselves.

These limits apply to this MCP's tools only, not to an assistant's own file or terminal access.

## Tools

| Tool | Purpose |
| --- | --- |
| `list_sources` | Accessible folders with their IDs, allowed paths, indexing status and model settings |
| `search_local` | Search documents, images and code; `asset_kind: "code"` limits it to code |
| `read_symbol` | Read a result by `id`, or its enclosing class, section or file by `parent_id` |
| `read_code_file` | Read current file text (extracted text for PDF/DOCX) |
| `read_image` | View an image preview |
| `refresh_index` | Queue an incremental rescan |

Searches cover the project when `source_id` is omitted. Pass a `source_id` from `list_sources` to search a granted folder. Results are concise by default; `response_format: "detailed"` adds scores and source details. Paths are relative to the indexed folder.

## HTTP API

The app and the bridge use these endpoints; all require the bearer key.

| Endpoint | Purpose |
| --- | --- |
| `GET /status` | Readiness, source counts, settings and errors |
| `GET/POST /sources`, `DELETE /sources/{id}` | List, add or revoke indexed folders (app only) |
| `GET/PUT /mcp-access` | Per-project grants (app only) |
| `GET/PUT /settings` | Model settings (app only) |
| `POST /search` | Search; `mode` is `auto`, `semantic`, `lexical` or `hybrid` |
| `GET /file`, `GET /symbol/{id}`, `GET /image` | Bounded reads |
| `POST /reindex` | Queue a rescan |

MCP requests carry the project in an `X-Local-Search-Project` header and cannot use the app-only endpoints.

## Single-repository mode

The original `serve` mode indexes one repository on port 8765, without folders, grants or a bearer key. Start it as described in [development](development.md#single-repository-mode), then connect:

```sh
codex mcp add repo-code-search -- \
  "/absolute/path/to/SemanticSearchMCP/.venv/bin/code-search" mcp --url http://127.0.0.1:8765
```

It offers `search_code`, `read_symbol`, `read_code_file`, `index_status` and `refresh_index`.
