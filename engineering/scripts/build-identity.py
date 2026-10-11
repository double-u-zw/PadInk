#!/usr/bin/env python3
"""Read-only, reproducible source identity for both app bundles, including uncommitted source.
The manifest contains relative source paths and SHA256s, never local signing configuration.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

SOURCE_DIRS = ("Sources", "Apps", "Hosts")
SOURCE_FILES = ("Package.swift", "Config/Identity.xcconfig", "Config/Version.xcconfig", "engineering/scripts/generate-project.py")


def identity(root):
    root = Path(root).resolve()
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, stderr=subprocess.DEVNULL, text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        marker = root / "SOURCE_COMMIT"
        head = marker.read_text().strip() if marker.exists() else "unknown"
    paths = [p for name in SOURCE_DIRS for p in (root / name).rglob("*")
             if p.is_file() and p.suffix in (".swift", ".plist", ".entitlements", ".metal", ".json", ".png", ".pdf", ".xcprivacy")]
    paths += [root / name for name in SOURCE_FILES if (root / name).is_file()]
    files = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(paths))}
    digest = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    revision = head[:12] if len(head) >= 12 and all(c in "0123456789abcdef" for c in head) else "unknown"
    return {"head": head, "sourceSHA256": digest, "label": revision + "+" + digest[:12], "files": files}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    result = identity(args.root)
    print(json.dumps(result, ensure_ascii=False, indent=2) if args.json else result["label"])
