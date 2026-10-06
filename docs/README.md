# Local Search: documentation

One file per app, service, or project-wide concern. Commands below assume the repository root as the working directory, including when reading a page under `docs/`.

## App and service

| Document | What it covers |
| --- | --- |
| [Mac app](mac-app.md) | Build/open, choosing sources, searching, previews, supported files, lifecycle and packaging limits |
| [Model settings](model.md) | Precision, dimensions, text limits, vision loading, image detail, query prefixes and index rebuilds |
| [MCP and HTTP API](mcp.md) | Assistant connection, project grants, tools, endpoints and settings contracts |
| [Command-line service](cli.md) | General workspace service, original single-repository mode and overrides |

## Project-wide concerns

| Document | What it covers |
| --- | --- |
| [Architecture](architecture.md) | Code map, shared runtime, extraction, incremental indexing, retrieval and concurrency |
| [Privacy and access](privacy.md) | Folder boundaries, revocation, authentication, local state and cloud-assistant data flow |
| [Development](development.md) | Setup, builds, isolated experiments, change rules and which checks to run |
| [Validation and measurements](validation.md) | Fixture tests, real-model checks, retrieval benchmark results and evidence limits |
| [Assistant instructions](agent-instructions.md) | Guidance to copy into an indexed project's AGENTS.md or CLAUDE.md |

## Measured artifacts

- [workspace-smoke.json](workspace-smoke.json): disposable real-model checks for text/images, settings, MCP and revocation.
- [benchmark.json](benchmark.json): rankings and timings for the 12-question TABNext retrieval benchmark.
- [Benchmark cases](../examples/tabnext-queries.json): hand-authored queries and expected symbols.

The JSON files are generated evidence, not configuration or promises of general performance. Keep their paths aligned with the scripts that produce them; do not replace measurements with invented values.

The root [README](../README.md) is the quick start and [AGENTS.md](../AGENTS.md) is the automatically discovered agent guidance. Project documentation lives here; upstream model files under `models/` remain part of the local checkpoint.
