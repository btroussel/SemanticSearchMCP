# Validation and measurements

Use the check appropriate to the change. Fixture tests, real-model smoke checks, retrieval benchmarks and full assistant evaluations establish different things.

## Fixture tests

```sh
.venv/bin/pytest -q
```

Tests use temporary sources and fixture embedders. They cover indexing/cache reuse, file freshness, hierarchy, extraction, source boundaries, revocation, per-project MCP grants, settings validation/persistence, index compatibility and concurrency. They do not establish real-model retrieval quality or run indexed projects’ tests/training. A tokenizer test can use the local tokenizer without loading GPU model weights.

## Disposable real-model workspace smoke

```sh
.venv/bin/python scripts/check-workspace.py
```

The script starts a separate real-model service with disposable state and synthetic code, documents and images. It checks French image queries, code/document retrieval, live model-option changes, all supported vector dimensions and image budgets, retrieval prefixes, BF16 text-only reload, stdio MCP, path boundaries and revocation. It rewrites [workspace-smoke.json](workspace-smoke.json), so only include the output when relevant to the change. If the checkpoint is unavailable, report that the real-model check could not run.

These are functional checks on small fixtures, not representative retrieval-quality, peak-memory, FP32/BF16 speed comparisons or full-agent speed benchmarks. A passing BF16 smoke check does not establish a performance benefit.

## Original MCP smoke

```sh
.venv/bin/python scripts/check-mcp.py --symbol my_function
```

This script targets the original service on port 8765. Pass a function or class defined in the indexed repository. It asserts five tools, lexical code search, parent/source reads and traversal rejection. Run it only against that intended service. General-service MCP is exercised by the disposable workspace smoke instead.

## Retrieval benchmark

```sh
# Once index_status reports ready:
.venv/bin/python scripts/benchmark.py --cases my-queries.json
```

The cases file is a JSON list of hand-authored questions about the indexed repository, each with the expected file and symbol:

```json
[{"query": "Where is the retry delay for failed uploads computed?", "path": "src/uploads.py", "symbol": "backoff_delay"}]
```

The benchmark never runs the indexed repository's code. It saves exact rankings and timings to `.code-search/benchmark.json` by default. It compares semantic retrieval, FTS5 lexical retrieval, and hybrid retrieval; FTS5 is not an agent using ripgrep. Semantic runs first and includes query encoding; hybrid reuses the query embedding. This measures retrieval, not end-to-end Codex or Claude Code performance.

On an initial, unpublished 12-question sample from one Python repository, semantic search found 12/12 expected symbols in the top five, lexical search found 8/12, and equal-weight hybrid search found 9/12. That result motivated semantic retrieval for natural-language questions in auto mode. The sample is small and hand-authored; evaluate your own questions before generalizing.

## Full assistant evaluations

No full Codex/Claude Code evaluation is recorded by these artifacts. Measure full answer time and correctness with and without retrieval on representative tasks before claiming an assistant speedup. The lexical benchmark is FTS5 BM25, not an agent choosing ripgrep commands. Hybrid’s cached query timings should not be compared as independent inference timings.

See [development](development.md) for the checks required by each type of source change.
