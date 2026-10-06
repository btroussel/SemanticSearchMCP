"""Download the pinned EmbeddingGemma 2 checkpoint with resumable, hash-verified transfers.

Only this explicit command uses the network; model loading and inference stay offline.
"""
from __future__ import annotations

import hashlib
import json
import logging
import shutil
import sys
import time
from collections.abc import Callable
from pathlib import Path

import httpx

MODEL_REPO = "google/embeddinggemma-2"
MODEL_REVISION = "914f7f89142e33e77833254d9c9b90c3cef7303b"
HUB_URL = "https://huggingface.co"
# (path, size, sha256) for every file of the pinned revision, verified against the Hub's LFS/git hashes.
MODEL_FILES = (
    ("1_Pooling/config.json", 90, "8759bdf7c77efc7df7723f64856a593c8943b71ee38baf2a88771fbaf78438f9"),
    ("2_Normalize/config.json", 97, "cdb09dfca347a56aa2d691744e38d5ad3c7cbc2834e7181272b9a15328b82524"),
    ("README.md", 21730, "b677a0ee2818c36f091b65fd3d9b4baea9f04d53b02b49cae916c74bf9682037"),
    ("chat_template.jinja", 1016, "4b852efc0b9960283e735363331e6f325b33bc74bdbaa076f595bc4e9b94d85e"),
    ("config.json", 4455, "b8f1e9931b57fbc054acdb445c41765d55b0074c58d145fa82839941ad1b5bb3"),
    ("config_sentence_transformers.json", 1565, "031e56a498d33c349ab489a21885bcfe25b4fcba841149dc99e1e90d4a7c28f5"),
    ("model.safetensors", 1488915288, "197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79"),
    ("modules.json", 413, "3d02572a0455b832de67fb8e63a54981bc7e8b46e337c95e917bd8122a533bfd"),
    ("preprocessor_config.json", 511, "ea2ae257e901064abdd98dceb19f2b0da06af600bed15e0f99f5c85c37ee9d78"),
    ("processor_config.json", 1788, "168f6a08522f3ce5dea596d94d003af2fd691742d4f41fe1f9d8cce76bfbf69c"),
    ("sentence_bert_config.json", 747, "b1bcd9f2dce3ae863b359e87d0710b5dbc3314a59ecb4e2f97c7778fc8e4b228"),
    ("tokenizer.json", 32170510, "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"),
    ("tokenizer.model", 4689013, "e594c8a90eb08d8bda498ff4747977dc827ae0c3c56b5c0d41a605a22d02ef03"),
    ("tokenizer_config.json", 1599, "17bd5d6e9364ca49a534e1502076593317c298d4a663623091ed45388f004874"),
)
CHUNK = 1 << 20


def _hash(path: Path, digest=None):
    digest = digest or hashlib.sha256()
    with path.open("rb") as file:
        while block := file.read(CHUNK):
            digest.update(block)
    return digest


def download_model(destination: Path, progress: Callable[[int, int], None] | None = None,
                   client: httpx.Client | None = None) -> Path:
    """Download into destination, publishing the folder only after every file is verified.

    Interrupted downloads resume from a sibling ``.partial`` folder. An existing destination is
    never overwritten or deleted.
    """
    destination = destination.expanduser().absolute()
    if destination.exists():
        if all((destination / name).is_file() for name, _, _ in MODEL_FILES):
            return destination
        raise FileExistsError(f"{destination} exists but is not a complete model; choose an empty location")
    partial = destination.with_name(destination.name + ".partial")
    total = sum(size for _, size, _ in MODEL_FILES)
    done = 0
    owned = client is None
    client = client or httpx.Client(timeout=httpx.Timeout(60, connect=20), follow_redirects=True, trust_env=True)
    try:
        for name, size, sha256 in MODEL_FILES:
            target = partial / name
            if target.is_file() and target.stat().st_size == size:
                done += size
                progress and progress(done, total)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            part = target.with_name(target.name + ".part")
            offset = part.stat().st_size if part.is_file() else 0
            if offset > size:
                part.unlink()
                offset = 0
            digest = _hash(part) if offset else hashlib.sha256()
            done += offset
            url = f"{HUB_URL}/{MODEL_REPO}/resolve/{MODEL_REVISION}/{name}"
            headers = {"Range": f"bytes={offset}-"} if 0 < offset < size else {}
            if offset < size:
                with client.stream("GET", url, headers=headers) as response:
                    response.raise_for_status()
                    if offset and response.status_code != 206:
                        done -= offset
                        offset = 0
                        digest = hashlib.sha256()
                    with part.open("ab" if offset else "wb") as file:
                        for block in response.iter_bytes(CHUNK):
                            file.write(block)
                            digest.update(block)
                            done += len(block)
                            progress and progress(done, total)
            if part.stat().st_size != size or digest.hexdigest() != sha256:
                part.unlink(missing_ok=True)
                raise ValueError(f"Downloaded {name} does not match the expected checksum; run the download again")
            part.replace(target)
            progress and progress(done, total)
        destination.parent.mkdir(parents=True, exist_ok=True)
        partial.replace(destination)
        return destination
    finally:
        if owned:
            client.close()


def main(destination: Path, json_progress: bool = False) -> None:
    logging.getLogger("httpx").setLevel(logging.WARNING)
    last = 0.0

    def report(done: int, total: int):
        nonlocal last
        now = time.monotonic()
        if now - last < 0.2 and done < total:
            return
        last = now
        if json_progress:
            print(json.dumps({"downloaded": done, "total": total}), flush=True)
        else:
            print(f"\rDownloading {MODEL_REPO}: {done / 1e9:.2f} / {total / 1e9:.2f} GB", end="", file=sys.stderr, flush=True)

    anchor = destination.expanduser().absolute()
    while not anchor.exists():
        anchor = anchor.parent
    if shutil.disk_usage(anchor).free < sum(size for _, size, _ in MODEL_FILES):
        raise SystemExit("Not enough free disk space for the model (about 1.5 GB)")
    path = download_model(destination, report)
    if not json_progress:
        print(file=sys.stderr)
    print(json.dumps({"model": str(path)}), flush=True)
