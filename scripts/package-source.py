#!/usr/bin/env python3
from pathlib import Path
import os
import zipfile
import re

root = Path(__file__).resolve().parent.parent
version = (root / "VERSION").read_text().strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise ValueError("VERSION must contain a semantic app version")
destination = root / "dist" / f"Hongguo-iPhone-{version}-source.zip"
destination.parent.mkdir(exist_ok=True)
excluded = {".git", ".build", ".swiftpm", ".swift-cache", ".agents", ".codex", ".aws", "node_modules", "build", "dist", "__pycache__", "xcuserdata", "DerivedData"}
private_suffixes = {".p12", ".pfx", ".pem", ".key", ".mobileprovision", ".provisionprofile", ".ipa", ".pyc", ".xcuserstate"}
source_directories = {".github", "Backend", "Sources", "Tests", "Tools", "docs", "iOS", "scripts"}
root_files = {".gitignore", "LICENSE", "Package.swift", "README.md", "VERSION"}
files = []
for directory, subdirectories, filenames in os.walk(root, followlinks=False):
    folder = Path(directory)
    subdirectories[:] = sorted(name for name in subdirectories
                              if name not in excluded and not name.endswith(".xcarchive")
                              and not (folder / name).is_symlink()
                              and (folder != root or name in source_directories))
    for name in filenames:
        if folder == root and name not in root_files:
            continue
        files.append(folder / name)
with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(files):
        relative = file.relative_to(root)
        if any(part in excluded or part.endswith(".xcarchive") for part in relative.parts) or file.is_symlink() or not file.is_file():
            continue
        if (file.name in {".DS_Store", "sample.mp4", "probe-result.json"}
            or file.name.startswith("._")
            or (file.name.startswith(".env") and file.name != ".env.example")
            or file.suffix.lower() in private_suffixes):
            continue
        archive.write(file, Path("Hongguo-iPhone") / relative)
print(destination)
