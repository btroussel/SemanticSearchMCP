# Local Search

A native macOS app and local MCP service for searching user-authorized code, documents, and images with EmbeddingGemma 2. One background service shares an offline model across folders and assistants.

## Install

Requires a Mac with Apple Silicon and macOS 14 or newer.

1. Download `Local-Search-<version>.dmg` from the [latest release](https://github.com/btroussel/SemanticSearchMCP/releases/latest) and drag **Local Search** to Applications.
2. Open it. The app is not notarized by Apple yet, so macOS blocks the first launch: open **System Settings → Privacy & Security** and choose **Open Anyway**.
3. Click **Install**. The app downloads its search engine (Python 3.12 and libraries, about 1.4 GB) and the [EmbeddingGemma 2 model](https://huggingface.co/google/embeddinggemma-2) (1.5 GB) once. If you already have the model, choose **Use a folder I already have…** instead of downloading it again.

After setup, indexing and search run offline. Everything the app installs or stores lives in `~/Library/Application Support/Local Search/`; to uninstall, delete the app and that folder.

### Build from source

Requires [uv](https://docs.astral.sh/uv/) and Xcode command-line tools.

```sh
uv sync --extra dev
.venv/bin/python scripts/build-mac-app.py          # standalone app, same first-launch setup
open '.code-search/Local Search.app'
```

For development, `.venv/bin/code-search download-model` puts the model in `models/embeddinggemma-2/` and `scripts/build-mac-app.py --dev` links the app to this checkout instead; see [development](docs/development.md).

Choose folders and file types in the app, then search with your own words. No folder is authorized by default. **Settings / Réglages** (Command-comma) controls the interface language, precision, dimensions, text limits and image encoding. **Connect an assistant / Connecter un assistant** provides MCP commands and project-specific grants. The interface follows your macOS language preference by default, with English as the fallback; you can also select a language in Settings.

Indexing and search computation stay local; snippets and image previews requested by a cloud assistant can be sent to its provider. Network access is used only during setup, as described in [privacy](docs/privacy.md).

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

## License

[Apache-2.0](LICENSE). The EmbeddingGemma 2 checkpoint is downloaded separately and is also distributed under Apache-2.0.
