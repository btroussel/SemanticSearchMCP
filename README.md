# Local Search

A native macOS app and local MCP service for searching user-authorized code, documents, and images with EmbeddingGemma 2. One background service shares an offline model across folders and assistants.

## Start

Python 3.12+ and macOS 14+ are required. The local checkpoint belongs at `models/embeddinggemma-2/`.

```sh
uv sync --extra dev
.venv/bin/python scripts/build-mac-app.py
open '.code-search/Local Search.app'
```

Choose folders and file types in the app, then search with your own words. No folder is authorized by default. **Réglages** (Command-comma) controls precision, dimensions, text limits and image encoding. **Connecter un assistant** provides MCP commands and project-specific grants.

The generated `.app` is a development build tied to this checkout’s Python environment and model, **not a standalone installer**. Indexing and search computation stay local; snippets and image previews requested by a cloud assistant can be sent to its provider.

## Documentation

Start with the [documentation index](docs/README.md). Detailed behavior, commands and limitations live under `docs/`.

| Topic | Guide |
| --- | --- |
| Choosing folders, search and previews | [Mac app](docs/mac-app.md) |
| Precision, dimensions and other model options | [Model settings](docs/model.md) |
| Connecting an assistant and project access | [MCP and HTTP API](docs/mcp.md) |
| Workspace and single-repository services | [CLI](docs/cli.md) |
| Code map, indexing and retrieval | [Architecture](docs/architecture.md) |
| Boundaries, revocation and stored data | [Privacy and access](docs/privacy.md) |
| Setup, builds and contribution checks | [Development](docs/development.md) |
| Tests, smoke checks and measured results | [Validation](docs/validation.md) |

Coding agents should read [AGENTS.md](AGENTS.md). Guidance for assistants working in indexed projects is in [docs/agent-instructions.md](docs/agent-instructions.md).
