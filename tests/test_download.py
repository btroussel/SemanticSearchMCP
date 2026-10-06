import hashlib

import httpx
import pytest

from semantic_search import download


@pytest.fixture
def files(monkeypatch):
    contents = {"config.json": b'{"a": 1}', "nested/weights.bin": bytes(range(256)) * 40}
    monkeypatch.setattr(download, "MODEL_FILES", tuple(
        (name, len(data), hashlib.sha256(data).hexdigest()) for name, data in contents.items()))
    monkeypatch.setattr(download, "CHUNK", 1000)
    return contents


def hub(contents, requests, corrupt=False, ranges=True):
    def handler(request):
        requests.append(request)
        prefix = f"/{download.MODEL_REPO}/resolve/{download.MODEL_REVISION}/"
        assert request.url.host == "huggingface.co" and request.url.path.startswith(prefix)
        data = contents[request.url.path[len(prefix):]]
        if corrupt:
            data = data[:-1] + b"!"
        if ranges and "range" in request.headers:
            start = int(request.headers["range"].removeprefix("bytes=").removesuffix("-"))
            return httpx.Response(206, content=data[start:])
        return httpx.Response(200, content=data)
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_download_verifies_files_and_publishes_complete_folder(tmp_path, files):
    requests, seen = [], []
    target = download.download_model(tmp_path / "model", lambda done, total: seen.append((done, total)),
                                      hub(files, requests))
    assert target == tmp_path / "model"
    assert {name: (target / name).read_bytes() for name in files} == files
    assert not (tmp_path / "model.partial").exists()
    total = sum(map(len, files.values()))
    assert seen[-1] == (total, total) and all(done <= total for done, _ in seen)


@pytest.mark.parametrize("ranges", [True, False])
def test_interrupted_download_resumes_or_restarts(tmp_path, files, ranges):
    data = files["nested/weights.bin"]
    part = tmp_path / "model.partial/nested/weights.bin.part"
    part.parent.mkdir(parents=True)
    part.write_bytes(data[:3000])
    requests = []
    download.download_model(tmp_path / "model", client=hub(files, requests, ranges=ranges))
    assert (tmp_path / "model/nested/weights.bin").read_bytes() == data
    resumed = [r for r in requests if r.url.path.endswith("weights.bin")][0]
    assert resumed.headers["range"] == "bytes=3000-"


def test_checksum_mismatch_never_publishes_the_model(tmp_path, files):
    with pytest.raises(ValueError, match="checksum"):
        download.download_model(tmp_path / "model", client=hub(files, [], corrupt=True))
    assert not (tmp_path / "model").exists()
    assert not list((tmp_path / "model.partial").rglob("*.part"))


def test_existing_destination_is_reused_or_left_untouched(tmp_path, files):
    complete = tmp_path / "complete"
    for name, data in files.items():
        (complete / name).parent.mkdir(parents=True, exist_ok=True)
        (complete / name).write_bytes(data)
    requests = []
    assert download.download_model(complete, client=hub(files, requests)) == complete and not requests
    other = tmp_path / "other"
    other.mkdir()
    (other / "notes.txt").write_text("keep")
    with pytest.raises(FileExistsError):
        download.download_model(other, client=hub(files, requests))
    assert (other / "notes.txt").read_text() == "keep" and not requests


def test_manifest_matches_local_checkpoint_when_available():
    from pathlib import Path
    path = Path(__file__).resolve().parents[1] / "models/embeddinggemma-2"
    if not (path / "config.json").is_file():
        pytest.skip("Local checkpoint unavailable")
    for name, size, sha256 in download.MODEL_FILES:
        if size < 50_000_000:
            assert download._hash(path / name).hexdigest() == sha256, name
        assert (path / name).stat().st_size == size, name
