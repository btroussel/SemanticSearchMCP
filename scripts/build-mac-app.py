#!/usr/bin/env python3
"""Build a development .app linked to this checkout's Python runtime and model."""
import plistlib
import shutil
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build", "-c", "release", "--package-path", str(root / "macos")], check=True)
binary_dir = subprocess.check_output(["swift", "build", "-c", "release", "--package-path", str(root / "macos"), "--show-bin-path"], text=True).strip()
app = root / ".code-search" / "Local Search.app"
binary = app / "Contents/MacOS/LocalSearch"
binary.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(Path(binary_dir) / "LocalSearch", binary)
info = {"CFBundleExecutable": "LocalSearch", "CFBundleIdentifier": "dev.localsearch.mac",
        "CFBundleName": "Local Search", "CFBundleDisplayName": "Local Search",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
        "SearchServiceExecutable": str(root / ".venv/bin/code-search"),
        "SearchModelPath": str(root / "models/embeddinggemma-2")}
with (app / "Contents/Info.plist").open("wb") as file:
    plistlib.dump(info, file)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
print(app)
