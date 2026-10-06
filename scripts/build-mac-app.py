#!/usr/bin/env python3
"""Build Local Search.app.

By default the bundle is standalone: it carries uv, the backend wheel and hash-locked requirements,
and installs Python, libraries and the model on first launch. --dev links the bundle to this
checkout's environment and model instead. --dmg also writes a disk image for distribution.
"""
import argparse
import hashlib
import os
import plistlib
import shutil
import subprocess
import tempfile
import tomllib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--dev", action="store_true", help="Link to this checkout's .venv and models/ instead of bundling")
parser.add_argument("--dmg", action="store_true", help="Also create a distributable disk image")
args = parser.parse_args()
if args.dev and args.dmg:
    parser.error("--dmg requires a standalone build")

root = Path(__file__).resolve().parents[1]
version = tomllib.loads((root / "pyproject.toml").read_text())["project"]["version"]
output = root / ".code-search"
subprocess.run(["swift", "build", "-c", "release", "--package-path", str(root / "macos")], check=True)
binary_dir = subprocess.check_output(["swift", "build", "-c", "release", "--package-path", str(root / "macos"), "--show-bin-path"], text=True).strip()
app = output / "Local Search.app"
shutil.rmtree(app, ignore_errors=True)
binary = app / "Contents/MacOS/LocalSearch"
binary.parent.mkdir(parents=True)
shutil.copy2(Path(binary_dir) / "LocalSearch", binary)
resources = app / "Contents/Resources"
resources.mkdir(parents=True, exist_ok=True)
resource_bundle = resources / "LocalSearch_LocalSearch.bundle"
shutil.copytree(Path(binary_dir) / resource_bundle.name, resource_bundle)
languages = sorted(path.stem for path in (root / "macos/Sources/LocalSearch/Resources").glob("*.lproj"))
info = {"CFBundleExecutable": "LocalSearch", "CFBundleIdentifier": "dev.localsearch.mac",
        "CFBundleName": "Local Search", "CFBundleDisplayName": "Local Search",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": version,
        "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": languages,
        "LSMinimumSystemVersion": "14.0", "LSArchitecturePriority": ["arm64"], "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": "Apache-2.0"}

if args.dev:
    info["SearchServiceExecutable"] = str(root / ".venv/bin/code-search")
    info["SearchModelPath"] = str(root / "models/embeddinggemma-2")
else:
    backend = app / "Contents/Resources/backend"
    backend.mkdir(parents=True)
    uv = shutil.which("uv")
    if not uv:
        raise SystemExit("uv is required to build a standalone app: https://docs.astral.sh/uv/")
    with tempfile.TemporaryDirectory() as temporary:
        subprocess.run([uv, "build", "--wheel", "--out-dir", temporary, str(root)], check=True)
        wheel = next(Path(temporary).glob("*.whl"))
        shutil.copy2(wheel, backend / wheel.name)
    subprocess.run([uv, "export", "--frozen", "--no-dev", "--no-emit-project", "--no-header",
                    "--format", "requirements-txt", "--project", str(root),
                    "--output-file", str(backend / "requirements.txt")], check=True, stdout=subprocess.DEVNULL)
    shutil.copy2(os.path.realpath(uv), backend / "uv")
    shutil.copy2(root / "LICENSE", backend / "LICENSE")
    (backend / "NOTICE").write_text(
        "Local Search is licensed under Apache-2.0 (see LICENSE).\n"
        "The bundled uv executable (https://github.com/astral-sh/uv) is used under its Apache-2.0 license (see LICENSE).\n"
        "Python, Python packages and the EmbeddingGemma 2 model are downloaded on first launch under their own licenses.\n")
    digest = hashlib.sha256()
    for name in ("requirements.txt", wheel.name):
        digest.update((backend / name).read_bytes())
    (backend / "version").write_text(f"{version}-{digest.hexdigest()[:16]}\n")

with (app / "Contents/Info.plist").open("wb") as file:
    plistlib.dump(info, file)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
print(app)

if args.dmg:
    dmg = output / f"Local-Search-{version}.dmg"
    with tempfile.TemporaryDirectory() as staging:
        shutil.copytree(app, Path(staging) / app.name, symlinks=True)
        (Path(staging) / "Applications").symlink_to("/Applications")
        dmg.unlink(missing_ok=True)
        subprocess.run(["hdiutil", "create", "-volname", "Local Search", "-srcfolder", staging,
                        "-format", "UDZO", "-ov", str(dmg)], check=True, stdout=subprocess.DEVNULL)
    print(dmg)
