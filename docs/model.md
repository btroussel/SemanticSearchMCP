# Model settings

The shared runtime uses a local EmbeddingGemma 2 checkpoint and performs inference offline: the app's downloaded copy in `~/Library/Application Support/Local Search/models/embeddinggemma-2/` (or a folder chosen at setup), and `models/embeddinggemma-2/` for development commands. `code-search download-model` fetches the pinned revision. The normal Mac app loads text and vision encoders; audio is omitted. The original single-repository mode loads text only.

## Options and tradeoffs

Open **Settings** in the sidebar or press **Command-comma** to configure the shared model:

| Option | Choices and default | Tradeoff |
| --- | --- | --- |
| Model precision | **float32**, bfloat16 | BF16 uses half the bytes per model weight and may improve speed; gains depend on hardware and kernels. FP16 is unsupported and is not offered. |
| Vector dimensions | **768**, 512, 256, 128 | Smaller vectors reduce storage and similarity-search work, not model inference work. Quality drops more at 128, especially for images. Stored vectors remain float32 regardless of inference precision. |
| Text input limit | 256–8,192 tokens; **4,096** | Larger inputs can use more time and memory. Titles, prefixes, and special tokens count toward the limit. |
| Image encoder | **Enabled** in the normal app; text only is also available | Disabling vision reduces model memory. Remove sources authorizing images before disabling it; original files are kept. Enabling it does not authorize any folder. |
| Image detail | 70, 140, **280**, 560, 1,120 tokens | Higher budgets can capture finer details, with more processing and memory. This is independent of the text limit. |
| Query task | **Automatic**, code retrieval, document/image search, question answering, fact checking | Selects the model's query prefix. Automatic uses code retrieval for code-only sources and general search for other sources. Question answering retrieves passages; it does not generate answers. |

All options are saved in private `settings.json` and survive restarts. Saving an embedding-affecting change finishes/cancels in-flight indexing between batches, clears incompatible chunks and cached vectors, and queues a rebuild of every authorized folder. Source IDs, folder authorization, exclusions, and originals are preserved; search results refill as indexing progresses. Interrupted rebuilds recover on restart. Changing only the query task clears cached query embeddings and leaves document vectors intact. Changing image detail while vision is disabled does not rebuild the text index.

Long text blocks are further split with the local tokenizer when needed, including single-line documents, so their remaining text is indexed instead of discarded. Image inputs are not truncated to the configured text limit. Audio/video, classification, and clustering workflows are not exposed by this search app.

The [settings API](mcp.md#settings-api) exposes the same options to the native app. MCP assistants can inspect options through `list_sources` but cannot change them. `--text-only` remains a hard service restriction. Old settings containing only `max_tokens` remain compatible.

BF16 text/image inference, all vector dimensions and image budgets, retrieval prefixes, live rebuilds, and text-only model reload are covered by the disposable [real-model smoke check](workspace-smoke.json). These checks establish functionality on this Mac, not representative speed or retrieval-quality gains.

## Precision and performance

Float32 is the default. Bfloat16 is the other supported inference precision and keeps float32's exponent range while using fewer bits for precision. Float16 has a narrower numerical range than these formats: EmbeddingGemma 2 activations can overflow, producing NaNs or silently degraded embeddings, so FP16 is not offered.

BF16 passed the local real-model text/image smoke checks on this Mac. This establishes compatibility, not a speedup or equivalent retrieval quality for every workload. Half the bytes per model weight does not mean half the total process memory or twice the speed. Device selection prefers CUDA, then Apple MPS, then CPU. CPU can be selected with `workspace --device cpu`.

Reducing vector dimensions speeds the comparison step and reduces vector storage; it does not reduce the model's encoding workload. Queries and documents must use the same dimension and the shortened vectors must be normalized. The runtime requests dimension truncation and normalization together.

## Retrieval task prefixes

Queries use `CodeRetrieval`, `SearchQuery`, `QuestionAnswering`, or `FactChecking`, according to the selected option. Documents retain their title/content formatting; changing the query task does not re-embed the corpus. Automatic selects code retrieval for code-only sources and general search for mixed/document/image sources.

Classification, clustering and symmetric similarity tasks require a different workflow and are not exposed by this retrieval app. The model's audio/video capabilities are also outside the current app scope.

The upstream model card is kept in the checkpoint at `models/embeddinggemma-2/README.md`; see [Google's model card](https://huggingface.co/google/embeddinggemma-2) for its published precision and dimension guidance. That file is upstream material, not project documentation to move or edit.
