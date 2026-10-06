# Command-line services

Run commands from the repository root after [development setup](development.md). `code-search` and `local-search` invoke the same Python implementation.

## General workspace service

```sh
.venv/bin/code-search workspace --model models/embeddinggemma-2
```

This is the Mac app’s backend on loopback port **8766**, using private state at `~/Library/Application Support/Local Search/`. It starts with no authorized folders; authorize them in the app. Every general endpoint requires the private bearer key. See [MCP/API](mcp.md) for the bridge and [privacy](privacy.md) for stored data and access.

`--device cpu` avoids MPS. `--text-only` omits vision and rejects image-source authorization; the app cannot override that service restriction. `--max-tokens 2048` overrides the saved token limit for that invocation. Omitting it uses the saved value, or 4,096 initially. The other model options are saved through app settings.

For isolated service experiments, use `--state /absolute/disposable/state`, a separate `--port`, and temporary sources. `--no-watch` disables watching; periodic reconciliation remains. The interval must be at least five seconds and defaults to 300.

## Original single-repository mode

```sh
uv sync --extra dev
.venv/bin/code-search serve \
  --repo /absolute/path/to/repository \
  --model models/embeddinggemma-2 \
  --db .code-search/index.sqlite \
  --exclude 'vendor/' --interval 300 --port 8765
```

The downloaded checkpoint in `models/embeddinggemma-2/` is used with text-only encoders, float32, and no model downloads. Device selection prefers CUDA, then Apple MPS, then CPU. Initial indexing takes time; `status` remains available while files are published incrementally.

In another terminal:

```sh
.venv/bin/code-search status
.venv/bin/code-search search "Where is the retry delay for failed uploads computed?"
```

Indexing never imports or executes the indexed repository's code and never edits its source. Keeping the database under this project's ignored `.code-search/` directory keeps index data out of the indexed repository.

Use `--max-tokens 4096` with `index` or `serve` to configure the token limit. A changed limit automatically rebuilds an existing compatible index and clears its cached embeddings. `workspace --max-tokens 2048` overrides the saved app setting for that invocation; otherwise workspace mode uses the saved limit or the initial default of 4,096.

`--dimensions 256` reduces vector storage without reducing the model's inference workload. In this original mode, changing the model, dimensions, repository, or exclusions requires a new database path. Token-limit changes and supported chunking-version upgrades can rebuild a compatible index automatically. Workspace mode handles its model-option rebuilds in place through app settings.

Use `index` with the same `--repo`, `--model`, `--db`, device, dimensions, token-limit and exclusion arguments for a one-shot index build. `serve` adds HTTP, watching and periodic reconciliation. The original service uses port **8765**; the CLI `search`, `status`, and non-general `mcp` commands target it by default.

The original service binds locally but does not use the general-service source/grant/bearer-key contract. It is for an explicitly selected repository. Original MCP connection and tool mappings are in [MCP/API](mcp.md#original-single-repository-connection).

## Command reference

```sh
.venv/bin/code-search --help
.venv/bin/code-search workspace --help
.venv/bin/code-search serve --help
.venv/bin/code-search index --help
.venv/bin/code-search mcp --help
.venv/bin/code-search search --help
```

The retrieval benchmark needs cases written for your repository; see [validation](validation.md) before running it.
