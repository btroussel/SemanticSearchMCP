# Agent guidance

Local Search is a macOS app and local MCP service for searching user-authorized code, documents and images with EmbeddingGemma 2. Start with `README.md` and read the docs it links to when a task needs them.

```sh
uv sync --extra dev
.venv/bin/pytest -q
swift build --package-path macos
.venv/bin/python scripts/build-mac-app.py --dev && open '.code-search/Local Search.app'
```

## Invariants

- No folder is authorized by default; folders and project grants are managed in the app, never through MCP tools.
- Path boundaries, ignore rules and secret-file exclusions apply to both discovery and reads; reject traversal and symlinks.
- Every general-service endpoint requires the bearer key and binds to loopback. Never print or commit `access.key`.
- Revocation blocks reads immediately, and revoked results are never published. Index cleanup survives restarts. Original files are never touched.
- The model loads offline in the service and is shared; the MCP bridge stays lightweight. Indexed projects are never executed or modified.
- Long content is split into chunks, never silently truncated. Token-limit validation lives in `settings.py`. Settings changes keep saved configuration and indexes consistent.
- When a shared interface changes, update the Python API, MCP tools, Swift client and docs together. Keep both `workspace` and `serve` modes working.

## Working here

- Use temporary folders and a disposable `--state`/`--port` for experiments, never the user's live index.
- Backend changes: run the relevant tests and the full suite, and add regression tests for boundaries, revocation, caching or concurrency. Swift changes: `swift build --package-path macos`.
- Changes to embeddings, extraction or end-to-end MCP: run `scripts/check-workspace.py` if the model checkpoint is present, and say so if it could not run.
- Don't edit model weights, `.venv`, generated bundles or measured JSON by hand. Don't infer retrieval quality or assistant speedups from the small checks.
- Releases are ad-hoc signed and not notarized; describe them that way.
- Update the docs when a lasting feature, limit or architecture choice changes. Describe only how things work now, briefly; the docs are not a changelog, so leave history, experiment results and minor UI details to git.

## Using local-search while working

If the local-search MCP is available, use it for natural-language discovery and `rg` for exact identifiers. If this workspace isn't indexed or the service is unavailable, use regular file tools; do not authorize folders yourself.
