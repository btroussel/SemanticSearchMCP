"""Apple MLX runtime for EmbeddingGemma 2, preferred on Apple silicon.

The adapter mirrors the subset of SentenceTransformer.encode used by the embedder, so prompts,
truncation, image budgets and normalization stay identical to the PyTorch path.
"""
from __future__ import annotations

import importlib.util
import json
import os
import platform
import sys
from pathlib import Path

import numpy as np


def available() -> bool:
    """MLX needs Apple silicon macOS and an mlx-vlm build that includes EmbeddingGemma 2."""
    if sys.platform != "darwin" or platform.machine() != "arm64":
        return False
    try:
        return (importlib.util.find_spec("mlx") is not None
                and importlib.util.find_spec("mlx_vlm.models.embedding_gemma2") is not None)
    except (ImportError, ValueError):
        return False


def clear_cache():
    import mlx.core as mx
    mx.clear_cache()


def memory() -> dict:
    import mlx.core as mx
    active = mx.get_active_memory()
    return {"allocated_mb": round(active / 1e6, 1), "driver_mb": round((active + mx.get_cache_memory()) / 1e6, 1)}


class Model:
    def __init__(self, path: Path, precision: str, images: bool, max_seq_length: int):
        # Float32 must stay float32; MLX would otherwise allow TF32 matmuls on recent GPUs.
        os.environ.setdefault("MLX_ENABLE_TF32", "0")
        import mlx.core as mx
        from mlx_vlm.embedding_loader import load_embedding_model
        from mlx_vlm.models.embedding_gemma2 import EmbeddingGemma2Processor
        from mlx_vlm.utils import load_config

        if not mx.metal.is_available():
            raise RuntimeError("MLX Metal device unavailable")
        config = load_config(path)
        config["audio_config"] = None
        if not images:
            config["vision_config"] = None
        self.model = load_embedding_model(path, config=config)
        self.dtype = getattr(mx, precision)
        self.model.set_dtype(self.dtype)
        mx.eval(self.model.parameters())
        self.processor = EmbeddingGemma2Processor.from_pretrained(str(path), local_files_only=True)
        self.prompts = json.loads((path / "config_sentence_transformers.json").read_text())["prompts"]
        self.images = images
        self.max_seq_length = max_seq_length

    def encode(self, items: list, prompt_name: str | None = None, prompt: str | None = None,
               truncate_dim: int | None = None, batch_size: int = 4, processing_kwargs: dict | None = None,
               **_) -> np.ndarray:
        import mlx.core as mx
        prefix = prompt if prompt is not None else self.prompts[prompt_name] if prompt_name else ""
        image_tokens = ((processing_kwargs or {}).get("image") or {}).get("max_soft_tokens")
        result = [None] * len(items)
        texts = [i for i, item in enumerate(items) if isinstance(item, str)]
        for offset in range(0, len(texts), batch_size):
            batch = texts[offset:offset + batch_size]
            encoded = self.processor.tokenizer([prefix + items[i] for i in batch], padding=True, truncation=True,
                                               max_length=self.max_seq_length, return_tensors="np")
            vectors = self._run(input_ids=mx.array(encoded["input_ids"]),
                                attention_mask=mx.array(encoded["attention_mask"]))
            for i, vector in zip(batch, vectors):
                result[i] = vector
        for i, item in enumerate(items):
            if isinstance(item, str):
                continue
            if not self.images:
                raise ValueError("Image encoder is disabled")
            if prefix:
                raise ValueError("Image inputs are encoded without a prompt")
            options = {"max_soft_tokens": image_tokens} if image_tokens else {}
            # Image inputs are never truncated to the text limit.
            content = [{"type": "image", "image": item}]
            inputs = self.processor.apply_chat_template([[{"role": "user", "content": content}]], tokenize=True,
                                                        return_dict=True, return_tensors="mlx", **options)
            inputs = {key: value.astype(self.dtype) if mx.issubdtype(value.dtype, mx.floating) else value
                      for key, value in inputs.items()}
            result[i] = self._run(**inputs)[0]
        vectors = np.stack(result) if result else np.zeros((0, truncate_dim or 768), dtype=np.float32)
        if truncate_dim:
            vectors = vectors[:, :truncate_dim]
        return vectors / np.linalg.norm(vectors, axis=1, keepdims=True)

    def _run(self, **inputs) -> np.ndarray:
        import mlx.core as mx
        embeddings = self.model(**inputs).text_embeds.astype(mx.float32)
        return np.array(embeddings)
