"""Offline text-only EmbeddingGemma runtime, lazily loaded and shared."""
from __future__ import annotations

import threading
import gc
from pathlib import Path

import numpy as np

from .settings import DEFAULT_MAX_TOKENS, ModelSettings, QUERY_PROMPTS, validate_max_tokens


class Embedder:
    def __init__(self, model_path: Path, device: str = "auto", dimensions: int = 768, images: bool = False,
                 max_tokens: int = DEFAULT_MAX_TOKENS, precision: str = "float32",
                 image_tokens: int = 280, query_task: str = "auto"):
        self.path = model_path.expanduser().resolve()
        if not (self.path / "model.safetensors").is_file():
            raise ValueError(f"Local model checkpoint not found at {self.path}")
        options = ModelSettings(dimensions=dimensions, max_tokens=max_tokens, precision=precision,
                                images=images, image_tokens=image_tokens, query_task=query_task)
        for key, value in options.model_dump().items():
            setattr(self, key, value)
        self.device = device
        self.tokenizer = None
        self.tokenizer_lock = threading.Lock()
        self.condition = threading.Condition()
        self.busy = False
        self.waiting_queries = 0
        self.model = None
        self.memory = {}
        stamp = (self.path / "model.safetensors").stat()
        self.checkpoint_fingerprint = f"embeddinggemma2:{self.path}:{stamp.st_size}:{stamp.st_mtime_ns}"

    @property
    def fingerprint(self):
        value = f"{self.checkpoint_fingerprint}:{self.dimensions}:{self.precision}"
        if self.images:
            value += ":vision"
            if self.image_tokens != 280:
                value += f":image_tokens={self.image_tokens}"
        return value

    def configuration(self):
        return {key: getattr(self, key) for key in ModelSettings.model_fields}

    def configure(self, **changes):
        options = ModelSettings(**{**self.configuration(), **changes})
        with self.condition:
            self.condition.wait_for(lambda: not self.busy)
            reload = options.precision != self.precision or options.images != self.images
            if reload:
                self.model = None
                self.memory = {}
                gc.collect()
                if self.device == "mps":
                    import torch
                    torch.mps.empty_cache()
            for key, value in options.model_dump().items():
                setattr(self, key, value)
            if self.model is not None:
                self.model.max_seq_length = self.max_tokens

    def _load(self):
        if self.model is None:
            import torch
            from sentence_transformers import SentenceTransformer
            device = self.device
            if device == "auto":
                device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
            self.device = device
            # float16 overflows this model; only float32 and bfloat16 are supported.
            self.model = SentenceTransformer(
                str(self.path), device=device, local_files_only=True,
                config_kwargs={"audio_config": None} if self.images else {"vision_config": None, "audio_config": None},
                model_kwargs={"torch_dtype": getattr(torch, self.precision)},
            )
            self.model.max_seq_length = self.max_tokens

    def set_max_tokens(self, value: int):
        value = validate_max_tokens(value)
        with self.condition:
            self.condition.wait_for(lambda: not self.busy)
            if self.model is not None:
                self.model.max_seq_length = value
            self.max_tokens = value

    def count_tokens(self, text: str) -> int:
        # Chunking needs only the local tokenizer, not GPU model weights. Include
        # special tokens; the caller supplies the document's title/prefix too.
        with self.tokenizer_lock:
            if self.tokenizer is None:
                from transformers import AutoTokenizer
                self.tokenizer = AutoTokenizer.from_pretrained(str(self.path), local_files_only=True)
            return len(self.tokenizer.encode(text, add_special_tokens=True, truncation=False))

    def encode(self, texts: list, query: bool = False, task: str = "code") -> np.ndarray:
        with self.condition:
            if query:
                self.waiting_queries += 1
            self.condition.wait_for(lambda: not self.busy and (query or self.waiting_queries == 0))
            self.busy = True
            if query:
                self.waiting_queries -= 1
        try:
            self._load()
            import torch

            def run(batch_size):
                options = {"processing_kwargs": {"image": {"max_soft_tokens": self.image_tokens}}} if self.images else {}
                if any(not isinstance(item, str) for item in texts):
                    # The app's text chunk budget must not truncate expanded image tokens.
                    options["processing_kwargs"]["text"] = {"truncation": False}
                selected_task = task if self.query_task == "auto" else self.query_task
                return self.model.encode(
                    texts, prompt_name=QUERY_PROMPTS[selected_task] if query else None, prompt="" if not query else None,
                    normalize_embeddings=True, truncate_dim=self.dimensions,
                    batch_size=batch_size, show_progress_bar=False, convert_to_numpy=True,
                    **options,
                )

            result = None
            try:
                result = run(4)
            except RuntimeError as exc:
                if self.device != "mps" or "out of memory" not in str(exc).lower():
                    raise
            if result is None:
                # Exit the exception scope before retrying so failed-frame tensors can be released.
                gc.collect()
                torch.mps.empty_cache()
                result = run(1)
        finally:
            try:
                if self.device == "mps" and self.model is not None:
                    import torch
                    # Variable-length SDPA batches can retain a large Metal allocation pool.
                    torch.mps.empty_cache()
                    self.memory = {"allocated_mb": round(torch.mps.current_allocated_memory() / 1e6, 1),
                                   "driver_mb": round(torch.mps.driver_allocated_memory() / 1e6, 1)}
            finally:
                with self.condition:
                    self.busy = False
                    self.condition.notify_all()
        result = np.asarray(result, dtype=np.float32)
        if not np.isfinite(result).all():
            raise RuntimeError("Model produced non-finite embeddings")
        return result
