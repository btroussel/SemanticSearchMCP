# Privacy and access

## What is read

Only folders you add in the app are indexed, limited to the file types you choose, your exclusions and ignore files (`.gitignore`, `.code-searchignore`, `.cursorignore`). Dependency and build directories, `.env`, `.pem` and `.key` files, symlinks and paths outside the folder are refused, both when indexing and when reading files back. Indexed projects are read, never run or modified.

Assistants see only their own project unless you grant more folders to that project; see [MCP](mcp.md#project-access). Revoking a folder or a grant blocks new reads immediately, and a revoked folder's index is deleted in the background, even if the app was quit midway.

## What is stored

Everything is stored in `~/Library/Application Support/Local Search/`, readable only by your user account: settings, folder list, grants, SQLite indexes (including text excerpts and vectors, not encrypted), logs, and the `access.key` that every API request must present. The service only listens on `127.0.0.1`. Never share `access.key`.

## What leaves the Mac

- **During setup only:** Python from [python-build-standalone](https://github.com/astral-sh/python-build-standalone) on GitHub, libraries from PyPI and the model from Hugging Face. These requests contain no folder or file information.
- **To your assistant:** snippets and image previews the assistant requests are sent to its provider, like any other tool output.

Indexing and search themselves never use the network.
