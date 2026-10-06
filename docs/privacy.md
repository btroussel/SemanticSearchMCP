# Privacy and access

These rules describe the current local service and app. They do not govern an assistant’s separate terminal or filesystem tools.

## Indexing sources

Start with no authorized folders. Choose each source, allowed file types and exclusions in the Mac app. Overlapping sources are rejected. The backend enforces path boundaries, allowed types and ignore rules both during discovery and when reading current content; symlinks and traversal are rejected. Common generated/dependency directories and `.env`, `.pem`, `.key` files are excluded.

The indexer reads source data; it never imports, executes or modifies indexed projects. Enabling image encoding does not authorize a folder. Disabling it requires removing sources that authorize images first, keeping the access decision explicit.

## MCP project boundaries

The app’s indexing authorization and an assistant’s project scope are separate. By default, MCP can access only the bridge’s project folder within authorized sources. Extra folders or subfolders require a saved grant for that project in **Connect an assistant → Project access**. A grant for one project does not authorize another.

Omitted `source_id` stays project-only. An explicit source ID permits only its project and granted prefixes; it cannot bypass scope. Searches, file reads, symbol expansion, previews, and reindex requests enforce the scope. The bridge checks that the backend acknowledges project-scoped access. See [connection and grant management](mcp.md).

## Revocation and cleanup

Revocation blocks new reads immediately, prevents in-flight indexing from publishing revoked results, and queues deletion of the source’s index data after in-flight work finishes. Interrupted cleanup completes on restart. Removing a source also removes its extra-folder MCP grants. Original files are never deleted. Removing a project grant and saving blocks that additional MCP access while the app’s indexing source can remain authorized.

## Authentication and stored data

The service enforces the selected folders, file types, exclusions, ignore files, and path boundaries. Symlinks and traversal paths are rejected. Common generated/dependency directories and `.env`, `.pem`, `.key` files are excluded.

The API binds to `127.0.0.1:8766` and requires a private bearer key for all endpoints. Configuration, plaintext index data, vectors, and logs are stored in the private `~/Library/Application Support/Local Search/` directory. Do not share its `access.key`. Index data is not encrypted at rest. The app-level source allowlist is enforced by the service; this development app is not App Sandbox-distributed and does not yet use sandbox bookmarks. macOS may separately prompt for protected-folder access.


Private state includes `sources.json`, `settings.json`, `mcp-access.json`, per-source SQLite databases, the bearer-key file, and service logs. The general-service state directory uses mode `0700`; its key and saved JSON configuration files use `0600`. Never print or share the key value. For experiments, use disposable sources, a separate state directory and a separate port; see [development](development.md).

The general API validates local hosts, requires authentication on every endpoint and provides no CORS allowance for unrelated web origins. The original single-repository service uses loopback port 8765 and does not use the general service’s bearer-key/source-grant contract; see [CLI modes](cli.md).

## Network use during setup

The app contacts the network only when you click **Install** or **Update** on its setup screen: the bundled uv downloads Python from [python-build-standalone](https://github.com/astral-sh/python-build-standalone) releases on GitHub and the hash-locked libraries from PyPI, and `code-search download-model` downloads the pinned EmbeddingGemma 2 revision from Hugging Face and verifies each file's SHA-256. Requests carry no indexed content or folder information. Setup files live in `runtime/`, `models/` and `setup.log` inside the private state directory.

## Local computation and cloud assistants

One offline model with text and vision encoders is shared across folders using the local checkpoint. Indexing and similarity computation stay on the Mac. Requested snippets and image previews returned to a cloud assistant can still be sent to that assistant’s provider. Local indexing is not a promise that retrieved content never leaves the device.
