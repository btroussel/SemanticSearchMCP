# Local Search for Mac

A native SwiftUI app, menu-bar shortcut, and shared local EmbeddingGemma 2 service. It starts with **no authorized folders** and has no dependency on a particular repository.

## Build and open

```sh
uv sync --extra dev
.venv/bin/python scripts/build-mac-app.py
open '.code-search/Local Search.app'
```

Choose **Ajouter un dossier**, select a folder in the Mac chooser, and authorize code, documents, and/or images. Exclusion patterns follow Git ignore syntax, one per line. Ordinary folders and Git repositories are supported. Saved changes are watched and reconciled every five minutes. The index persists across restarts.

Select a sidebar source to restrict search, choose a result-type filter, and describe what you need. Return starts a search; Command-K focuses the field. Select a result for a text/image preview; the Finder button reveals the original file. Choose **Gérer l’accès** to inspect a selected source, its exclusions and unreadable files, or revoke access. A right-click on a source also exposes these controls.


## Settings and assistants

Open **Réglages** in the sidebar or press **Command-comma** to configure the shared model. See [model settings](model.md) for precision, dimensions, text limits, image detail and rebuild behavior.

The **Connecter un assistant / MCP** panel provides connection commands and **Accès par projet** grants. See [MCP connection and project scope](mcp.md) before connecting an assistant. The app searches its authorized sources; MCP searches default to the assistant’s project.

## Source access and app lifecycle

Revocation blocks new reads immediately and queues deletion of the source database after any in-flight indexing batch finishes. Restarting finishes interrupted cleanup. Original files are never deleted. To change types or exclusions, remove and re-add the source with new settings. Overlapping sources are rejected to keep access unambiguous.

Closing the window keeps the service available. Reopen it through the menu-bar icon. Quitting stops the backend the app started; if it connected to an independently running backend, that process stays running.

## Supported files and limits

- **Code:** Python AST and supported Tree-sitter languages, with bounded blocks for other supported code/config formats.
- **Documents:** TXT, Markdown, RST, CSV, LOG, text-bearing PDF, and DOCX paragraphs/tables. PDF/DOCX ranges refer to extracted-text lines. Scanned PDFs need OCR, which is not included. Encrypted PDFs and PDFs above 200 pages are skipped and reported.
- **Images:** PNG, JPEG, WebP, GIF, BMP, TIFF. The vision encoder embeds pixels; retrieval by description does not depend on filenames or generated captions. GIFs use their first frame. Input images and previews are resized to at most 1024 pixels per side. HEIC, video, and audio are not supported yet.

Text files are limited to 512 KB, images and PDF/DOCX files to 20 MB, images to 40 megapixels, extracted text to 512K characters. Expanded DOCX content is bounded too. Unreadable files are reported in source details. No OCR, reranking, caller graph, or generated summaries are included.

## Current limitations

The `.app` is ad-hoc signed for development and points to this checkout's Python environment and local model. It is **not a standalone distributable installer yet**. Rebuild after moving the checkout. The app can be moved on this Mac while those configured paths stay valid. Python requires 3.12 or newer; the app targets macOS 14 or newer.

Large libraries and launch-at-login installation remain future work. The app is not distributed with App Sandbox and does not yet use sandbox bookmarks. macOS may separately prompt for protected-folder access.

See [privacy and local processing](privacy.md), [development](development.md), and [validation evidence](validation.md) for the corresponding boundaries and checks.
