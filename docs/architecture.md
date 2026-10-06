# Architecture

Local Search combines a native SwiftUI app, a general local HTTP service and a lightweight stdio MCP bridge. One shared runtime loads the offline model and schedules inference across authorized sources. The original single-repository service remains available separately.

## Code map

Python modules are under `semantic_search/`.

| File or directory | Responsibility |
| --- | --- |
| `cli.py` | Both `code-search` and `local-search` entry points; workspace and original modes |
| `download.py` | Pinned, SHA-256-verified, resumable model download (`download-model`); the only network code |
| `workspace.py` | Sources, persistent settings, shared service, authenticated HTTP API and source lifecycle |
| `access.py` | Per-project MCP grants and allowed source prefixes |
| `service.py` | Background workers, watches and the original HTTP API |
| `files.py` | Discovery, ignores, confined reads, document extraction and image handling |
| `chunks.py` | AST / Tree-sitter extraction, hierarchy and token-aware bounded chunks |
| `embeddings.py` | Offline loading, tokenizer, text/vision embeddings and inference scheduling |
| `settings.py` | Shared model-option defaults and validation |
| `index.py` | SQLite metadata, embedding caches, FTS5, vector search and freshness |
| `mcp_server.py` | Stdio HTTP bridge; no model loading |
| `macos/Sources/LocalSearch/LocalSearch.swift` | SwiftUI app, first-launch setup, service client and backend lifecycle |
| `macos/Sources/LocalSearch/Localization.swift`, `Resources/*.lproj/` | App language preference, resource lookup, translated interface and plural forms |
| `scripts/` | Standalone/development app and disk-image build, real-model smoke, MCP check and retrieval benchmark |
| `tests/` | Temporary-source fixture tests |

## Indexing and retrieval

For text and code, the pipeline is:

1. Discover source/text files, respecting `.gitignore`, `.code-searchignore`, `.cursorignore`, and explicit exclusions. Skip symlinks, dependencies, model weights, build outputs, `.env` files, and files above 512 KB.
2. Extract Python symbols with `ast`; supported other languages use Tree-sitter. Incomplete or unsupported syntax falls back to bounded line windows. Large functions get blocks; classes and files get source-derived outlines. No LLM-generated summaries are required.
3. Embed titled code documents with the documented EmbeddingGemma formatting and search questions with `CodeRetrieval`. Cache vectors by document content. Line-number-only moves can reuse unchanged function embeddings.
4. Commit each changed file atomically in SQLite. Watch saved files with a short debounce and reconcile the repository every five minutes. Delete entries for removed or excluded files. On restart, reuse the persisted index and warm the model.
5. In default `auto` mode, search natural-language behavior questions with normalized vector similarity and exact identifier/path queries with FTS5 BM25. Optional `hybrid` mode combines both using reciprocal rank fusion. Return bounded code snippets with paths, lines, symbol IDs, and parent IDs. Recheck source hashes; omit stale results and report their paths. If semantic inference fails in auto mode, return lexical results with an explicit degradation message.

Workspace sources also support extracted PDF/DOCX text and pixel-based image embeddings. Image retrieval by description uses the vision encoder, without generated captions or filename-based semantic embeddings. Discovery, extraction and previews retain the [app's format and size limits](mac-app.md#supported-files-and-limits).

SQLite stores metadata, vectors, and the lexical index. A cached NumPy matrix performs exact vector search. This keeps the first version simple and avoids a separate database service; it is **not** an approximate-nearest-neighbor index for millions of chunks. Queries get priority between small embedding batches, but can wait for an in-flight batch. MPS indexing and queries share GPU resources.

On Apple MPS, the runtime releases cached GPU allocations between calls and retries memory-limited batches with one item at a time. If GPU execution still fails, start the service with `--device cpu`; the saved index is compatible and completed files do not need to be embedded again.

File/class hierarchy and parent expansion are supported. Automatic caller graphs, recursive generated package summaries, and reranking are not implemented. Start with this measured baseline before adding them.


## Shared sources and settings

Each authorized source owns its index and worker while all sources share the embedder. Source configuration and saved model settings are separate from per-project assistant grants. See [privacy and access](privacy.md) for the boundaries.

Settings changes affecting embeddings finish/cancel current indexing between batches before clearing incompatible chunks, embedding caches, query caches and matrix snapshots. Model precision or encoder-loading changes release the loaded model so the next inference loads the selected configuration. Metadata and fingerprints keep restarted indexes compatible with the saved settings. Original single-repository model/dimension changes still require a new database; workspace mode can rebuild its source indexes in place.

Each source uses exact vector search. Cross-source searches merge per-source candidates; lexical/hybrid ranks come from separate indexes rather than a global BM25 index. Large-scale approximate search and full assistant evaluations are not implemented; see [validation](validation.md).
