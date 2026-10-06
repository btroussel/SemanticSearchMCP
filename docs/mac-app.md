# Mac app

A SwiftUI app with a menu-bar icon that runs the shared search service. Installation is in the [README](../README.md#install). Closing the window keeps the service running; quitting the app stops it. When a new version bundles a different backend, the setup screen offers **Update**.

## Folders

Add a folder, then choose which file types to index (code, documents, images) and any exclusions in Git ignore syntax. Folders that overlap an existing one are rejected. Changes are picked up when files are saved, and every folder is rescanned every five minutes.

Revoking a folder stops reads immediately and deletes its index in the background. Your files are never modified or deleted. To change a folder's types or exclusions, remove it and add it again.

## Search

Type a question in the search field (Command-K) and filter by folder or file type. Click a result to preview it with the matching lines highlighted, or use its menu to open it, reveal it in Finder or copy its path. Identical files show up once.

**Connect an assistant** gives the MCP commands and per-project access; see [MCP](mcp.md).

## Settings

**Settings** (Command-comma) holds the interface language (English or French, following macOS by default) and the model options:

| Option | Choices (default in bold) | Effect |
| --- | --- | --- |
| Precision | **float32**, bfloat16 | bfloat16 uses half the memory per weight; any speed gain depends on hardware. float16 is not offered because the model's activations can overflow. |
| Vector dimensions | **768**, 512, 256, 128 | Smaller vectors reduce storage and comparison cost, not encoding time. Quality drops most at 128. |
| Text input limit | 256–8,192 tokens, **4,096** | Larger chunks take more time and memory. Longer text is split, never cut off. |
| Image encoder | **On**, off | Turning it off saves memory. Remove folders that index images first. |
| Image detail | 70, 140, **280**, 560, 1,120 tokens | Higher values capture finer detail at a higher cost. |
| Query task | **Automatic**, code retrieval, document/image search, question answering, fact checking | Chooses the prefix added to queries. Automatic uses code retrieval for code-only folders and general search otherwise. |

Changes that affect stored vectors rebuild every index in the background, keeping folders and permissions; results fill in again as indexing progresses. Changing only the query task does not rebuild anything. Assistants can see these settings but not change them.

## Supported files and limits

- **Code:** Python is split by its syntax tree, other common languages with Tree-sitter; other text formats use line windows.
- **Documents:** TXT, Markdown, RST, CSV, LOG, PDF with a text layer and DOCX. Results in PDF/DOCX point to lines of the extracted text. There is no OCR, and encrypted PDFs or PDFs over 200 pages are skipped.
- **Images:** PNG, JPEG, WebP, GIF (first frame), BMP and TIFF, found by what they show rather than by file name. HEIC, video and audio are not supported.

Size limits: 512 KB per text file, 20 MB per PDF, DOCX or image, 40 megapixels per image, 512K extracted characters. Files that cannot be read are listed in the folder's details.

## Limitations

- Apple Silicon and macOS 14 or newer only; first-time setup needs an internet connection and about 3 GB of disk.
- Ad-hoc signed and not notarized, so the first launch needs **Open Anyway**.
- Not sandboxed; macOS may still ask for access to protected folders.
- Search compares against every stored vector, which suits personal folders, not millions of files.
