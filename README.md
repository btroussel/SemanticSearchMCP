# Local Search

A macOS app and local MCP service for searching your code, documents and images with natural language, using the [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) model. Indexing and search run on your Mac; one background service shares the model across folders and assistants.

## Install

Requires Apple Silicon and macOS 14 or newer. To let Claude Code or Codex do it for you, paste:

```text
Install Local Search by following the Install section of https://github.com/btroussel/SemanticSearchMCP#install, then connect it to yourself as an MCP server. Ask me whenever a step needs me in macOS or in the app.
```

1. Download `Local-Search-<version>.dmg` from the [latest release](https://github.com/btroussel/SemanticSearchMCP/releases/latest) and drag **Local Search** to Applications.
2. Open it. The app is not notarized, so macOS blocks the first launch: choose **Open Anyway** in **System Settings → Privacy & Security**.
3. Click **Install**. The app downloads Python with its libraries (about 1.7 GB) and the model (1.5 GB) once, or uses a model folder you already have.
4. Add the folders to index in the app. Nothing is indexed by default.
5. Connect an assistant, then start a new session:

   ```sh
   # Claude Code
   claude mcp add --scope user --transport stdio local-search -- \
     "$HOME/Library/Application Support/Local Search/runtime/venv/bin/code-search" mcp --general \
     --url http://127.0.0.1:8766 \
     --token-file "$HOME/Library/Application Support/Local Search/access.key"

   # Codex
   codex mcp add local-search -- \
     "$HOME/Library/Application Support/Local Search/runtime/venv/bin/code-search" mcp --general \
     --url http://127.0.0.1:8766 \
     --token-file "$HOME/Library/Application Support/Local Search/access.key"
   ```

   The app's **Connect an assistant** panel shows the same commands. By default, an assistant can only search its own project folder; see [MCP](docs/mcp.md).

Everything the app installs or stores lives in `~/Library/Application Support/Local Search/`. To uninstall, delete the app and that folder.

The network is used only during setup. Snippets and image previews that a cloud assistant requests are sent to its provider like any other tool output; see [privacy](docs/privacy.md).

## Build from source

Requires [uv](https://docs.astral.sh/uv/) and the Xcode command-line tools.

```sh
uv sync --extra dev
.venv/bin/python scripts/build-mac-app.py   # standalone app, same first-launch setup
open '.code-search/Local Search.app'
```

See [development](docs/development.md) for the `--dev` build linked to this checkout, the CLI and tests.

## Documentation

| Topic | Guide |
| --- | --- |
| Using the app, settings, supported files and limits | [Mac app](docs/mac-app.md) |
| Connecting assistants, project access, tools and API | [MCP](docs/mcp.md) |
| What is accessed, stored and sent | [Privacy](docs/privacy.md) |
| How it works, code map, builds, CLI and checks | [Development](docs/development.md) |

Coding agents working on this repository should read [AGENTS.md](AGENTS.md).

## License

[Apache-2.0](LICENSE). The EmbeddingGemma 2 checkpoint is downloaded separately and is also distributed under Apache-2.0.
