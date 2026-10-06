# MCP and HTTP API

The general service runs on loopback port **8766** with a private bearer key. The original single-repository service is separate on **8765**. The stdio bridge forwards requests; model loading and inference stay in the service.

## General-service connection

The **Connect an assistant / MCP** panel provides commands with your absolute paths. Replace the example paths below with the ones shown in the app.

```sh
codex mcp add local-search -- \
  "/absolute/path/to/SemanticSearchMCP/.venv/bin/code-search" mcp --general \
  --url http://127.0.0.1:8766 \
  --token-file "$HOME/Library/Application Support/Local Search/access.key"

claude mcp add --scope user --transport stdio local-search -- \
  "/absolute/path/to/SemanticSearchMCP/.venv/bin/code-search" mcp --general \
  --url http://127.0.0.1:8766 \
  --token-file "$HOME/Library/Application Support/Local Search/access.key"
```

Start a fresh assistant session and check `/mcp`. Official references: [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), [Claude Code MCP](https://code.claude.com/docs/en/mcp).

| Tool | Purpose |
| --- | --- |
| `list_sources` | Accessible folders, IDs, allowed prefixes, indexing status, model readiness and options |
| `search_local` | Search code, documents, and images; optionally across sources |
| `search_code` | Search implementations in an authorized source |
| `read_symbol` | Read a result by `id`, or expand to its enclosing class/file by `parent_id` |
| `read_code_file` | Read current source or extracted document text |
| `read_image` | Inspect an authorized image preview |
| `refresh_index` | Queue incremental indexing |

Search tools return a concise result by default: paths, lines, symbol and parent IDs, `source_id`, bounded code, and `duplicates` only when copies exist. Pass `response_format: "detailed"` to add ranking scores, `content_id`, and source names/paths. The tool schemas list the accepted `mode`/`asset_kind` values and the `limit`, `max_chars` and `max_lines` bounds. Service errors reach the assistant as the service's own message.

The MCP defaults to **the project folder only**. The bridge binds to its launch directory, or the explicit `mcp --general --project /absolute/project` option. `list_sources` reports that project and the allowed path prefixes within each accessible index. Verify the reported project: clients that launch MCP from another directory should use `--project`. The project must already be covered by an indexing source in the app; otherwise MCP searches return no results.

In **Connect an assistant → Project access**, choose the project, add extra folders (or subfolders of existing sources), and choose **Save permissions**. Grants persist for that project only. Remove a folder and save to revoke its MCP access immediately. Removing an indexing source also removes its additional-folder grants. Adding a folder for indexing does not grant every assistant access to it.

An omitted `source_id` searches only the project, even after extra folders are granted. File, symbol and image reads without a `source_id` use the indexing source containing the project; if the project spans several sources, pass the `source_id` from the result. To search an extra folder, pass its `source_id` from `list_sources` and optionally a relative `path_filter`. The backend enforces the allowed prefixes for searches, file reads, symbol expansion and image previews; passing a different source ID cannot bypass them. An explicit source may contain both project and granted subfolder scopes. File paths and filters remain relative to the indexing source, e.g. `my-project/` when the source is `~/Code`.

The app's own search still covers its authorized indexing sources. Folder authorization and MCP grants are absent from agent tools; manage them in the app. These controls govern this MCP's tools, not an assistant's separate terminal or filesystem tools. Each result includes `source_id`; source-specific reads require that ID. Add the [agent guidance](agent-instructions.md) to your `AGENTS.md` or `CLAUDE.md` for more consistent use. After upgrading, restart the app/service and open fresh assistant sessions; new bridges reject older services that cannot enforce project scope.

Try: “Use local-search to list this project's accessible sources, then find an image showing a blue bar chart in this project and inspect the best candidate with read_image.”

## General HTTP API

All endpoints require the private bearer key, including status, settings, images, and management. The general service disables its automatic OpenAPI/docs routes. Do not paste the key into documentation, logs, or shared commands; the bridge and native app read it from private state.

| Method and path | Purpose |
| --- | --- |
| `GET /status` | Service readiness, scoped source counts, effective model settings and errors |
| `GET /sources` | Accessible sources and, for MCP, the project and allowed prefixes |
| `POST /sources` | Authorize an indexing source through the app |
| `DELETE /sources/{source_id}` | Revoke indexing access and queue index cleanup |
| `GET /mcp-access?project=...` / `PUT /mcp-access` | Inspect/save per-project extra-folder grants through the app |
| `GET /settings` / `PUT /settings` | Read/update model options through the app |
| `POST /search` | Search accessible source content |
| `GET /file` | Bounded current source or extracted document text |
| `GET /symbol/{identifier}` | Read an indexed symbol or parent context |
| `GET /image` | Bounded image preview |
| `POST /reindex` | Queue an incremental rescan |

MCP requests carry `X-Local-Search-Project` as a local file URI. The backend enforces project scope and returns `X-Local-Search-Scoped: 1`; the bridge rejects older services without that marker. Project-scoped requests cannot call source, settings or grant-management endpoints. Folder authorization and grants are app actions, not MCP tools.

Search accepts `query`, `source_id`, `asset_kind`, `limit`, `path_filter`, `mode`, and `max_chars`. `asset_kind` is `code`, `documents`, `images`, or empty. Modes are `auto`, `semantic`, `lexical`, and `hybrid`. Paths and filters remain relative to the source. Results include `source_id`, bounded snippets, ranking information and paths. Identical copies of a file, in the same or another accessible source, share one result: `duplicates` lists up to ten other copies as `source_id`/`path` pairs, `duplicates_omitted` counts unlisted copies, and `content_id` is equal for identical content. Single-repository results list only `path`; the general response also reports `issues`, `stale_paths`, and `elapsed_ms`. See [architecture](architecture.md) for ranking and fallback behavior.

## Settings API

The authenticated `GET /settings` returns these fields: `max_tokens`, `dimensions`, `precision`, `images`, `image_tokens`, `query_task`, and the read-only `image_encoder_available` capability. `PUT /settings` accepts a partial update of the six editable fields and returns the effective options plus `reindex_queued`; omitted fields keep their current values. Unknown or invalid fields are rejected. MCP `list_sources` reports the options, but assistants cannot change them through MCP. `--text-only` remains a hard service restriction and cannot be overridden by saved settings or the app. Old settings containing only `max_tokens` remain compatible.

Editable field names and values correspond to the [model settings table](model.md). The partial update preserves omitted fields; supplying a capability or an unknown option is rejected. Precision, dimensions, text limits, and active image encoding/detail changes invalidate document vectors. Query-task changes invalidate only query embeddings.

## Original single-repository connection

These commands target the original service on port 8765, without general-service source IDs or project grants. Start it using the [single-repository CLI](cli.md#original-single-repository-mode).

Keep the service running. Register the bridge with an absolute executable path so spaces and different working directories work correctly:

```sh
codex mcp add repo-code-search -- \
  "/absolute/path/to/SemanticSearchMCP/.venv/bin/code-search" mcp \
  --url http://127.0.0.1:8765
```

For Claude Code, run this from the indexed repository. Local scope changes your private Claude configuration, not files in that repository:

```sh
cd /absolute/path/to/repository
claude mcp add --scope local --transport stdio repo-code-search -- \
  "/absolute/path/to/SemanticSearchMCP/.venv/bin/code-search" mcp \
  --url http://127.0.0.1:8765
```

Start a new agent session and check `/mcp`. The Codex entry is user-scoped, so the server explicitly instructs the agent to verify that the indexed repository matches its active workspace. See [agent guidance and a first prompt](agent-instructions.md). Configured tools may require a new session or client restart to appear.

Official connection references: [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) and [Claude Code MCP](https://code.claude.com/docs/en/mcp).

To remove the registrations:

```sh
codex mcp remove repo-code-search
# From the indexed repository:
claude mcp remove --scope local repo-code-search
```

## Original tools and API

| MCP tool | Local API | Purpose |
| --- | --- | --- |
| `search_code` | `POST /search` | Ranked semantic, lexical, or hybrid candidates |
| `read_symbol` | `GET /symbol/{id}` | Read a function/class or expand via its parent ID |
| `read_code_file` | `GET /file?path=...&start_line=1` | Read bounded current source |
| `index_status` | `GET /status` | Counts, repository, readiness, device, last update |
| `refresh_index` | `POST /reindex` | Queue an incremental rescan |

These tools take no `source_id`. `search_code` accepts the same concise/detailed `response_format` as the general bridge; the HTTP API always returns the detailed form.

```sh
curl -s http://127.0.0.1:8765/search \
  -H 'Content-Type: application/json' \
  -d '{"query":"where is the learning rate warmup configured?","limit":5,"path_filter":"src/"}'
```

The interactive API documentation is at `http://127.0.0.1:8765/docs` while running. The service binds only to loopback. Indexing and retrieval stay local; a connected cloud coding model can still receive the snippets returned by these tools.
