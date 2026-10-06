# Local Search for Mac

A native SwiftUI app, menu-bar shortcut, and shared local EmbeddingGemma 2 service. It starts with **no authorized folders** and has no dependency on a particular repository.

## Install and first launch

Install from the release disk image or build the app as described in the [README](../README.md#install). On first launch, the setup screen lists the **search engine** and the **EmbeddingGemma 2 model**. **Install** then:

1. runs the bundled [uv](https://docs.astral.sh/uv/) to download Python 3.12 into `runtime/python/` and install the hash-locked libraries and the Local Search backend into `runtime/venv/` (about 1.4 GB);
2. runs `code-search download-model` to fetch the pinned model revision into `models/embeddinggemma-2/` (1.5 GB), verifying every file's SHA-256.

Both paths are under `~/Library/Application Support/Local Search/`. Progress, **Cancel** and **Show log** (`setup.log`) are available during setup. A cancelled or interrupted model download resumes; the engine is installed into a staging folder and only replaces the previous one once complete. **Use a folder I already have…** selects an existing checkpoint containing `config.json`, `model.safetensors` and `tokenizer.json` instead of downloading.

When a new app version bundles a different backend or library lock, the setup screen offers **Update** and reinstalls the engine, reusing the uv download cache. A development build made with `scripts/build-mac-app.py --dev` skips setup and uses this checkout's `.venv` and `models/`.

Choose **Add a folder / Ajouter un dossier**, select a folder in the Mac chooser, and authorize code, documents, and/or images. Exclusion patterns follow Git ignore syntax, one per line. Ordinary folders and Git repositories are supported. Saved changes are watched and reconciled every five minutes. The index persists across restarts.

Select a sidebar source to restrict search, choose a result-type filter, and describe what you need. Return starts a search; Command-K focuses the field. Select a result for a text/image preview; the Finder button reveals the original file. Choose **Manage access / Gérer l’accès** to inspect a selected source, its exclusions and unreadable files, or revoke access. A right-click on a source also exposes these controls.


## Settings and assistants

Open **Settings / Réglages** in the sidebar or press **Command-comma** to configure the shared model. See [model settings](model.md) for precision, dimensions, text limits, image detail and rebuild behavior.

The **Connect an assistant / Connecter un assistant / MCP** panel provides connection commands and **Project access / Accès par projet** grants. See [MCP connection and project scope](mcp.md) before connecting an assistant. The app searches its authorized sources; MCP searches default to the assistant’s project.

## Interface language

In **Settings → Language** (**Réglages → Langue**), choose **Follow macOS** or an available translation. The default follows the preferred languages set in macOS, including an app-specific language preference, and falls back to English when no supported language matches. An explicit choice is saved locally and changes the app interface and menu-bar shortcut menu immediately, without rebuilding indexes or restarting the service.

Source names, paths, search queries, retrieved content, and backend diagnostic messages keep their original text. macOS-provided menus and system dialog controls follow the system's app language preference; the in-app choice controls Local Search's own text. To add a translation, see [the localization workflow](development.md#localization).

## Source access and app lifecycle

Revocation blocks new reads immediately and queues deletion of the source database after any in-flight indexing batch finishes. Restarting finishes interrupted cleanup. Original files are never deleted. To change types or exclusions, remove and re-add the source with new settings. Overlapping sources are rejected to keep access unambiguous.

Closing the window keeps the service available. Reopen it through the menu-bar icon. Quitting stops the backend the app started; if it connected to an independently running backend, that process stays running.

## Supported files and limits

- **Code:** Python AST and supported Tree-sitter languages, with bounded blocks for other supported code/config formats.
- **Documents:** TXT, Markdown, RST, CSV, LOG, text-bearing PDF, and DOCX paragraphs/tables. PDF/DOCX ranges refer to extracted-text lines. Scanned PDFs need OCR, which is not included. Encrypted PDFs and PDFs above 200 pages are skipped and reported.
- **Images:** PNG, JPEG, WebP, GIF, BMP, TIFF. The vision encoder embeds pixels; retrieval by description does not depend on filenames or generated captions. GIFs use their first frame. Input images and previews are resized to at most 1024 pixels per side. HEIC, video, and audio are not supported yet.

Text files are limited to 512 KB, images and PDF/DOCX files to 20 MB, images to 40 megapixels, extracted text to 512K characters. Expanded DOCX content is bounded too. Unreadable files are reported in source details. No OCR, reranking, caller graph, or generated summaries are included.

## Current limitations

The app is ad-hoc signed, not notarized: the first launch of a downloaded copy needs **Open Anyway** in System Settings → Privacy & Security. It requires Apple Silicon (PyTorch no longer ships Intel macOS builds) and macOS 14 or newer. First-launch setup needs an internet connection and about 3 GB of disk space. A `--dev` build points to this checkout's Python environment and model; rebuild it after moving the checkout.

Large libraries and launch-at-login installation remain future work. The app is not distributed with App Sandbox and does not yet use sandbox bookmarks. macOS may separately prompt for protected-folder access.

See [privacy and local processing](privacy.md), [development](development.md), and [validation evidence](validation.md) for the corresponding boundaries and checks.
