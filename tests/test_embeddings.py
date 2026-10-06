import numpy as np
import pytest
import torch

from local_code_search.embeddings import Embedder
from local_code_search.chunks import Chunk, _bound_chunk


def test_configurable_limit_is_applied_on_load_and_to_a_loaded_model(tmp_path, monkeypatch):
    import sentence_transformers
    (tmp_path / "model.safetensors").write_bytes(b"fixture")

    class Model:
        def __init__(self, *args, **kwargs):
            pass

    monkeypatch.setattr(sentence_transformers, "SentenceTransformer", Model)
    embedder = Embedder(tmp_path, device="cpu")
    embedder._load()
    assert embedder.model.max_seq_length == 4096
    embedder.set_max_tokens(1024)
    assert embedder.max_tokens == embedder.model.max_seq_length == 1024
    custom = Embedder(tmp_path, device="cpu", max_tokens=2048)
    custom._load()
    assert custom.model.max_seq_length == 2048


@pytest.mark.parametrize("value", [0, 255, 8193, 4096.0, True])
def test_invalid_token_limits_are_rejected(tmp_path, value):
    (tmp_path / "model.safetensors").write_bytes(b"fixture")
    with pytest.raises(ValueError, match="Maximum input tokens"):
        Embedder(tmp_path, max_tokens=value)


def test_real_tokenizer_bounds_multilingual_single_lines_without_losing_text():
    from pathlib import Path
    path = Path(__file__).resolve().parents[1] / "models/embeddinggemma-2"
    if not (path / "tokenizer.json").is_file():
        pytest.skip("Local checkpoint tokenizer unavailable")
    embedder = Embedder(path, device="cpu", max_tokens=4096)
    text = ("Résultats expérimentaux: 中文测试 🧪 accuracy 0.987. " * 1200) + "END_OF_PAPER"
    chunk = Chunk("original", "paper.txt", "paper.txt", "block", 1, 1, "file", text)
    parts = list(_bound_chunk(chunk, embedder.max_tokens, embedder.count_tokens))
    assert len(parts) > 1
    assert "".join(p.text for p in parts) == text
    assert len({p.id for p in parts}) == len(parts)
    assert all(embedder.count_tokens(p.document) <= 4096 for p in parts)
    assert all(p.start == p.end == 1 and p.parent_id == "file" for p in parts)
    assert embedder.model is None  # Chunking does not load GPU weights.


def test_mps_memory_retry_releases_cache_and_keeps_query_gate_usable(tmp_path, monkeypatch):
    (tmp_path / "model.safetensors").write_bytes(b"fixture")
    embedder = Embedder(tmp_path, device="mps")
    calls, cleanups = [], []

    class Model:
        def encode(self, texts, **kwargs):
            calls.append(kwargs["batch_size"])
            if len(calls) == 1:
                raise RuntimeError("MPS backend out of memory")
            return np.ones((len(texts), 768), dtype=np.float32)

    embedder.model = Model()
    monkeypatch.setattr(torch.mps, "empty_cache", lambda: cleanups.append(True))
    monkeypatch.setattr(torch.mps, "current_allocated_memory", lambda: 0)
    monkeypatch.setattr(torch.mps, "driver_allocated_memory", lambda: 0)
    assert embedder.encode(["code"]).shape == (1, 768)
    assert calls == [4, 1]
    assert len(cleanups) == 2
    assert not embedder.busy
    assert embedder.encode(["query"], query=True).shape == (1, 768)


def test_non_finite_output_is_rejected_without_locking_out_future_calls(tmp_path):
    (tmp_path / "model.safetensors").write_bytes(b"fixture")
    embedder = Embedder(tmp_path, device="cpu")

    class Model:
        def encode(self, texts, **kwargs):
            return np.full((len(texts), 768), np.nan, dtype=np.float32)

    embedder.model = Model()
    with pytest.raises(RuntimeError, match="non-finite"):
        embedder.encode(["code"])
    assert not embedder.busy


def test_model_options_reload_weights_and_preserve_query_gate(tmp_path, monkeypatch):
    import sentence_transformers
    (tmp_path / 'model.safetensors').write_bytes(b'fixture')
    loads, calls = [], []

    class Model:
        def __init__(self, *args, **kwargs):
            loads.append(kwargs)

        def encode(self, texts, **kwargs):
            calls.append(kwargs)
            return np.ones((len(texts), kwargs['truncate_dim']), dtype=np.float32)

    monkeypatch.setattr(sentence_transformers, 'SentenceTransformer', Model)
    embedder = Embedder(tmp_path, device='cpu', images=True)
    original = embedder.fingerprint
    embedder.encode(['doc'])
    embedder.configure(precision='bfloat16', dimensions=256, image_tokens=70, query_task='fact_checking')
    assert embedder.model is None and embedder.fingerprint != original
    assert embedder.encode(['claim'], query=True).shape == (1, 256)
    assert loads[-1]['model_kwargs']['torch_dtype'] == torch.bfloat16
    assert calls[-1]['prompt_name'] == 'FactChecking'
    from PIL import Image
    embedder.encode([Image.new('RGB', (32, 32))])
    assert calls[-1]['processing_kwargs'] == {'image': {'max_soft_tokens': 70}, 'text': {'truncation': False}}
    assert calls[-1]['prompt'] == '' and calls[-1]['prompt_name'] is None
    embedder.configure(images=False)
    embedder.encode(['doc'])
    assert loads[-1]['config_kwargs'] == {'vision_config': None, 'audio_config': None}
    assert 'processing_kwargs' not in calls[-1]
    assert not embedder.busy


@pytest.mark.parametrize('changes', [
    {'precision': 'float16'}, {'precision': 'int8'}, {'dimensions': 64},
    {'dimensions': 256.0}, {'image_tokens': 300}, {'images': 1},
    {'query_task': 'classification'}, {'max_tokens': None},
])
def test_invalid_model_options_leave_runtime_unchanged(tmp_path, changes):
    (tmp_path / 'model.safetensors').write_bytes(b'fixture')
    embedder = Embedder(tmp_path, device='cpu')
    before = embedder.configuration()
    with pytest.raises(ValueError):
        embedder.configure(**changes)
    assert embedder.configuration() == before
