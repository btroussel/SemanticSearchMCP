# Development

Python requires **3.12 or newer**; the Swift app targets **macOS 14 or newer**. Run commands from the repository root. Development commands expect the model checkpoint at `models/embeddinggemma-2/`; runtime loading is offline and never downloads models.

## Setup

```sh
uv sync --extra dev
.venv/bin/code-search download-model   # pinned revision, SHA-256 verified, resumable
.venv/bin/code-search --help
```

The two CLI names, `code-search` and `local-search`, share one implementation. See the [code map](architecture.md) and [CLI modes](cli.md).

## Version control

Git is initialized at the project root. The root `.gitignore` excludes the Python environment, model checkpoint, generated app/index state, Swift build output and Python caches. Project source, documentation and measured JSON artifacts can be tracked. Review `git status` and the diff before staging changes, especially when several agents share the checkout.

## Build the Mac app

```sh
swift build --package-path macos
.venv/bin/python scripts/build-mac-app.py --dev   # linked to this checkout
open '.code-search/Local Search.app'
```

`--dev` makes an ad-hoc signed bundle at `.code-search/Local Search.app` whose `Info.plist` points to this checkout’s `.venv/bin/code-search` and `models/embeddinggemma-2`, so it skips first-launch setup; rebuild after moving the checkout.

Without `--dev`, the script builds the standalone app (about 45 MB). `Contents/Resources/backend/` holds the `uv` executable, the backend wheel, `requirements.txt` exported from `uv.lock` with hashes, licenses, and a `version` stamp derived from the wheel and requirements. The app compares that stamp with `runtime/version` to decide whether setup or an engine update is needed. Add `--dmg` to also write `.code-search/Local-Search-<version>.dmg` for a GitHub release. Bump `version` in `pyproject.toml` for each release. Releases are Apple Silicon only.

To exercise first-launch setup without touching the live state or service, launch the binary with a disposable state folder and port:

```sh
LOCAL_SEARCH_STATE=/tmp/local-search-state LOCAL_SEARCH_PORT=18766 \
  '.code-search/Local Search.app/Contents/MacOS/LocalSearch'
```

Closing the app window keeps the service running; quitting stops only the backend started by that app. After backend/MCP upgrades, restart the app/service and open fresh assistant sessions.

## Localization

The app uses [standard Swift Package Manager localized resources](https://developer.apple.com/documentation/xcode/localizing-package-resources), with English as the development language in `macos/Package.swift`. Translations live in `macos/Sources/LocalSearch/Resources/<language>.lproj/Localizable.strings`; plural counts live in the companion `Localizable.stringsdict`. `Localization.swift` discovers available languages from the resource bundle, matches macOS preferences, and stores an explicit in-app choice in the app's `appLanguage` user default. Missing translated keys fall back to English.

To add a language:

1. Copy `en.lproj` to a language-tag directory such as `es.lproj` or `pt-BR.lproj` under `Resources`.
2. Translate string values, keeping the stable keys and format placeholders (`%1$@`, `%2$lld`, etc.) unchanged. Escape quotes and newlines as required by `.strings` syntax. Adjust the `.stringsdict` plural categories for the target language while retaining the `lld` integer type and `count` variable.
3. Use `L10n.string("key")` for new interface text, with arguments for formatted messages. Add each new key to every translation. Keep user content, paths, command lines, protocol values, and backend diagnostics out of the catalogs.
4. Run `swift test --package-path macos` and `swift build --package-path macos`, then rebuild the development app with `.venv/bin/python scripts/build-mac-app.py --dev`. The builder embeds the Swift resource bundle and declares the discovered languages in `Info.plist`; no hard-coded language list needs updating.
5. Open Settings and select the language. Check the main window, folder authorization, source access/revocation, result previews, assistant connection, Settings, and menu-bar shortcut menu for wrapping and clipped text. Return to **Follow macOS** to verify language matching.

Localization tests use temporary preferences and fixture resources. They check language matching, fallback, persistence, plural forms, translation keys and format placeholders without starting the backend or reading a user's index. The in-app language setting changes the app's own text immediately; system-provided menu/dialog controls use macOS's language preference. It does not change search/index settings or translate retrieved content and service errors.

## Isolated experiments

Use temporary sources and disposable state, never personal folders or the live user index. A separate port avoids the app’s port 8766 and the original service’s port 8765. For example, create the disposable path first, then start:

```sh
.venv/bin/code-search workspace \
  --model models/embeddinggemma-2 \
  --state /absolute/disposable/state --port 18766 \
  --device cpu --text-only --no-watch
```

The service still starts with no authorized folders and requires its private bearer key. Do not authorize folders or expand access on a user’s behalf as part of natural-language code discovery. See [agent instructions](agent-instructions.md) for using an existing index and [privacy](privacy.md) for state handling.

## Change and validation rules

Keep changes focused and preserve source IDs, allowed types, exclusions, path confinement, immediate revocation, offline inference, atomic indexing, embedding reuse, freshness checks and explicit semantic-failure fallback. Avoid silent truncation of source content. Model options and token-limit validation belong in `settings.py`; saved settings and index metadata must remain consistent.

Update the Python API, MCP contracts, Swift client and corresponding documentation together when a shared interface changes. Keep the original and general service modes working unless the task explicitly changes their scope. Preserve float32 as the default and MPS memory handling; inference changes need real-model validation.

Do not edit model weights, virtual environments, caches, generated bundles or live user state as source changes. Build outputs are generated by the build script. Do not modify or execute indexed projects as part of indexing. Measured JSON must come from the scripts’ actual output.

| Change | Required checks |
| --- | --- |
| Documentation only | Verify local links, paths and commands; runtime tests are unnecessary |
| Backend | Relevant pytest coverage and the full suite when feasible; meaningful regressions for changed boundaries, contracts, caches or concurrency |
| Swift | `swift build --package-path macos`; `swift test --package-path macos` for localization changes; bundle build for configuration/launch changes; inspect the affected UI when possible |
| Embeddings, documents/images or end-to-end MCP | Disposable real-model workspace smoke check when the checkpoint is available |
| Retrieval benchmark | Only an intended, ready single-repository service; check the cases and output path first |

The exact commands, generated outputs and evidence limits are in [validation](validation.md). Agent-specific guidance remains in the root [AGENTS.md](../AGENTS.md).
