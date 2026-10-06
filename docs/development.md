# Development

Requires Python 3.12+, [uv](https://docs.astral.sh/uv/) and the Xcode command-line tools. Run commands from the repository root.

```sh
uv sync --extra dev
.venv/bin/code-search download-model   # into models/embeddinggemma-2/, resumable
```

## Mac app

```sh
swift build --package-path macos
.venv/bin/python scripts/build-mac-app.py --dev
open '.code-search/Local Search.app'
```

`--dev` builds an app that uses this checkout's `.venv` and `models/` and skips first-launch setup; rebuild it if the checkout moves. Without `--dev`, the script builds the standalone app that installs everything on first launch; add `--dmg` for a release image and bump `version` in `pyproject.toml` for each release.

To try first-launch setup without touching your real state:

```sh
LOCAL_SEARCH_STATE=/tmp/local-search-state LOCAL_SEARCH_PORT=18766 \
  '.code-search/Local Search.app/Contents/MacOS/LocalSearch'
```

Translations are in `macos/Sources/LocalSearch/Resources/<lang>.lproj/`. To add a language, copy `en.lproj`, translate the values (keep keys and placeholders), and use `L10n.string("key")` for new text.

## Backend

```sh
.venv/bin/code-search workspace --model models/embeddinggemma-2
```

This is the service the app runs, on port 8766 with state in `~/Library/Application Support/Local Search/`. For experiments, use a disposable `--state` directory, another `--port` and temporary folders. `--text-only` disables images.

The model runs on [MLX](https://github.com/ml-explore/mlx) on Apple Silicon and on PyTorch elsewhere (CUDA, then MPS, then CPU). If MLX cannot load, the service logs a warning and uses PyTorch. `--device mlx|cuda|mps|cpu` forces a runtime; `--device mps` gives the PyTorch path on a Mac. Both runtimes produce interchangeable vectors, so switching does not rebuild indexes. EmbeddingGemma 2 support in `mlx-vlm` is pinned to a merged commit in `pyproject.toml` until it is released on PyPI. See `code-search <command> --help` for all options.

### Single-repository mode

The original mode indexes one repository without the app:

```sh
.venv/bin/code-search serve --repo /path/to/repo --model models/embeddinggemma-2 --db .code-search/index.sqlite
.venv/bin/code-search search "Where is the retry delay computed?"
```

It serves on port 8765. Changing the model, dimensions or repository needs a new `--db`.

## Checks

| Check | Command | Covers |
| --- | --- | --- |
| Python tests | `.venv/bin/pytest -q` | Indexing, boundaries, revocation, grants, settings, concurrency, with fixture embeddings |
| Swift tests | `swift test --package-path macos` | Localization |
| Real-model smoke | `.venv/bin/python scripts/check-workspace.py` | End to end with the real model, on disposable fixtures; rewrites [workspace-smoke.json](workspace-smoke.json) |
| Single-repo MCP | `.venv/bin/python scripts/check-mcp.py --symbol <name>` | MCP tools against a running `serve` |
| Retrieval benchmark | `.venv/bin/python scripts/benchmark.py --cases cases.json` | Semantic vs. full-text vs. hybrid ranking on a running `serve` |

Benchmark cases are a JSON list such as `[{"query": "...", "path": "src/uploads.py", "symbol": "backoff_delay"}]`, written for the indexed repository.

These checks show that features work; they do not measure overall retrieval quality or whether assistants get faster.

## How it works

The SwiftUI app starts a local Python HTTP service, which loads the model once and keeps an index per authorized folder. Assistants reach the service through a lightweight stdio MCP bridge.

**Indexing.** Find the files allowed by the folder's settings and ignore rules, then split them into chunks: functions and classes for code (Python syntax tree, Tree-sitter for other languages, line windows otherwise), heading sections for Markdown, reStructuredText and DOCX, pages for PDF, line windows for other text, whole images for pictures. Sections nest like classes and methods, so `parent_id` expands a result to its enclosing section. Each chunk is embedded, reusing cached vectors for unchanged content, and each file is stored in SQLite in one transaction. Saved files are re-indexed within seconds and each folder is rescanned every five minutes.

**Search.** In `auto` mode, natural-language queries use vector similarity and identifier-like queries use SQLite full-text search; `hybrid` combines the two. Queries limited to code, or covering only code-only folders, are embedded with the code retrieval prompt; other queries use the search prompt for every folder so scores stay comparable, unless the app's query task setting overrides both. If the model fails, search falls back to full-text and says so. Results whose file changed since indexing are dropped, and identical copies are merged. Vector search is exact over vectors held in memory, which suits personal folders, not millions of chunks.

## Code map

Python modules are in `semantic_search/`.

| File | Responsibility |
| --- | --- |
| `cli.py` | `code-search` / `local-search` commands |
| `workspace.py` | Authorized folders, settings, authentication and the HTTP API |
| `access.py` | Per-project MCP grants |
| `service.py` | Background indexing workers; original single-repository service |
| `files.py` | File discovery, ignore rules, confined reads, PDF/DOCX extraction, images |
| `chunks.py` | Splitting code and text into token-bounded chunks |
| `embeddings.py` | Model loading, runtime selection and text/image embedding |
| `mlx_runtime.py` | MLX model adapter used on Apple Silicon |
| `settings.py` | Model options and their validation |
| `index.py` | SQLite storage, full-text search and vector search |
| `mcp_server.py` | Stdio MCP bridge and the instructions it gives assistants |
| `download.py` | Model download (the only network code) |
| `macos/Sources/LocalSearch/` | Mac app and its translations |
| `scripts/` | App build, smoke checks and benchmark |
