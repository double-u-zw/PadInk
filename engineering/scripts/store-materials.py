#!/usr/bin/env python3
"""Validate/stage local App Store copy. No signing, device access, network or publication."""
import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import struct
import sys
import zipfile
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
MATERIALS = ROOT / "engineering/app-store"
CHAR_LIMITS = {"name": 30, "subtitle": 30, "description": 4000, "promotionalText": 170}
PENDING_FIELDS = ("copyright", "sku", "teamID", "bundleID", "priceAndTerritories",
                  "ageRatingQuestionnaire", "reviewContact", "publicSupportContact",
                  "macSignedDownloadURL", "appPrivacyFinalAnswers",
                  "exportComplianceFinalAnswers")
PENDING_FLAGS = ("nameAvailabilityConfirmed", "publicDocumentsUpdated", "testFlightUSBValidated")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local_path(relative, root=ROOT):
    path = (root / relative).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        raise ValueError(f"missing or unsafe local asset: {relative}")
    return path


def png_size(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"not PNG: {path.name}")
    return list(struct.unpack(">II", data[16:24]))


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "engineering/scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate(root=ROOT, materials=None, release=None, source_root=None):
    root = Path(root).resolve()
    materials = Path(materials or root / "engineering/app-store").resolve()
    meta = json.loads((materials / "metadata.json").read_text())
    if meta.get("materialRole") != "current-candidate":
        raise ValueError("only current-candidate materials may be staged; use --history for frozen materials")
    expected_target = {"variant": "release", "channel": "rc", "ipadDistribution": "testflight-app-store", "macDistribution": "developer-id-notarized"}
    if meta.get("target") != expected_target:
        raise ValueError("current materials must target TestFlight/App Store and notarized Developer ID Mac")
    architectures = meta.get("macArchitectures")
    if not isinstance(architectures, list) or not architectures or len(architectures) != len(set(architectures)) or not set(architectures) <= {"arm64", "x86_64"}:
        raise ValueError("current materials must declare valid Mac architectures")
    for name in ("START-HERE.txt", "candidate-notes.txt", "public/support.txt"):
        header = (materials / name).read_text().splitlines()[0]
        if meta["version"] not in header or not re.search(r"build\s+" + re.escape(meta["build"]) + r"\b", header):
            raise ValueError(f"{name} target differs from current candidate")
    version_text = (root / "Config/Version.xcconfig").read_text()
    for key, field in (("MARKETING_VERSION", "version"), ("CURRENT_PROJECT_VERSION", "build")):
        match = re.search(rf"^{key}\s*=\s*(\S+)", version_text, re.M)
        if not match or match[1] != meta[field]:
            raise ValueError(f"metadata {field} differs from Config/Version.xcconfig")
    lengths = {}
    pending = [field for field in PENDING_FIELDS if not meta.get(field)]
    pending += [field for field in PENDING_FLAGS if meta.get(field) is not True]
    # A reviewer demonstration can help explain the companion, but Apple does not
    # require a video for every app. Keep an explicitly requested video as a gate.
    video_required = meta.get("reviewVideoRequired", False)
    if not isinstance(video_required, bool):
        raise ValueError("reviewVideoRequired must be an explicit boolean")
    if video_required and not meta.get("reviewVideoURL"):
        pending.append("reviewVideoURL")
    for field in ("macSignedDownloadURL", "reviewVideoURL"):
        value = meta.get(field)
        if value and (not isinstance(value, str) or urlsplit(value).scheme != "https" or not urlsplit(value).netloc):
            raise ValueError(f"invalid HTTPS URL: {field}")
    for name, value in meta["urls"].items():
        if value and (urlsplit(value).scheme != "https" or not urlsplit(value).netloc):
            raise ValueError(f"invalid HTTPS URL: {name}")
    if not meta["urls"].get("support"):
        pending.append("final support URL displaying confirmed public contact")
    for lang, loc in meta["localizations"].items():
        lengths[lang] = {}
        for field, limit in CHAR_LIMITS.items():
            value = loc[field]
            if not value.strip() or len(value) > limit:
                raise ValueError(f"{lang} {field}: exceeds {limit} characters or empty")
            lengths[lang][field + "Characters"] = len(value)
        keywords = loc["keywords"]
        if len(keywords.encode("utf-8")) > 100 or any(len(k.strip()) < 3 for k in keywords.split(",")):
            raise ValueError(f"{lang} keywords: require <=100 UTF-8 bytes and each >2 characters")
        lengths[lang]["keywordsUTF8Bytes"] = len(keywords.encode("utf-8"))
        review = (materials / meta["reviewNotesFiles"][lang]).read_text()
        first_line = review.splitlines()[0]
        if meta["version"] not in first_line or not re.search(r"build\s+" + re.escape(meta["build"]) + r"\b", first_line):
            raise ValueError(f"{lang} review notes target differs from current candidate")
        lengths[lang]["reviewNotesUTF8Bytes"] = len(review.encode("utf-8"))
        if lengths[lang]["reviewNotesUTF8Bytes"] > 4000:
            raise ValueError(f"{lang} review notes exceed 4000 bytes")
        if "TO CONFIRM" in review or "待确认" in review or "待补" in review:
            pending.append(f"{lang} reviewer links/contact remain draft")
    inventory = json.loads((materials / "screenshots.json").read_text())
    icon = inventory["icon"]
    icon_path = local_path(icon["path"], root)
    if sha(icon_path) != icon["sha256"] or png_size(icon_path) != [1024, 1024]:
        raise ValueError("original iPad icon differs from inventory")
    approved = meta["approvedStoreScreenshots"]
    if not 1 <= len(approved) <= 10:
        pending.append("1–10 real approved iPad 13-inch landscape screenshots")
    for asset in approved:
        path = local_path(asset["path"], root)
        if asset.get("build") != meta["build"] or sha(path) != asset["sha256"]:
            raise ValueError("approved screenshot build/hash mismatch")
        # The prepared workflow uses lossless PNG originals; Apple also accepts JPEG.
        if png_size(path) not in inventory["requiredLandscapeSizes"]:
            raise ValueError("approved screenshot is not an accepted 13-inch landscape PNG")
        if asset.get("realFunctionVerified") is not True or asset.get("privateContentChecked") is not True:
            pending.append(f"screenshot requires human verification: {asset['path']}")
    source = load_script("build-identity").identity(root)
    candidate_source = None
    candidate_mode = None
    material_source = None
    if source_root and not release:
        raise ValueError("separate frozen source requires --release")
    if release:
        rc = load_script("rc-release")
        manifest, _ = rc.check(root, Path(release))
        candidate_source = manifest["source"]
        candidate_mode = manifest["release"]["mode"]
        current_source, _ = rc.source_snapshot(Path(source_root).resolve() if source_root else root)
        if manifest["release"]["version"] != meta["version"] or manifest["release"]["build"] != meta["build"]:
            raise ValueError("frozen release version/build differs from current materials")
        if candidate_source != current_source:
            raise ValueError("frozen release source differs from current checkout; do not stage stale materials")
        if manifest["release"]["macArchitectures"] != sorted(architectures):
            raise ValueError("current materials Mac scope differs from frozen candidate")
        signing_identity = manifest.get("releaseIdentity", {})
        if signing_identity:
            if meta.get("bundleID") and meta["bundleID"] != signing_identity["PADINK_IPAD_BUNDLE_ID"]:
                raise ValueError("current materials bundle ID differs from actual signed candidate")
            if meta.get("teamID") and meta["teamID"] != signing_identity["DEVELOPMENT_TEAM"]:
                raise ValueError("current materials team differs from actual signed candidate")
            # Team identity is already retained privately in the signed release manifest.
            if signing_identity.get("DEVELOPMENT_TEAM") and "teamID" in pending:
                pending.remove("teamID")
        if source_root:
            rc.ensure_frozen(Path(source_root).resolve(), manifest)
            material_source, _ = rc.source_snapshot(root)
            if source["sourceSHA256"] != candidate_source["sourceSHA256"]:
                raise ValueError("material checkout app inputs differ from exact frozen build inputs")
    return meta, inventory, {"version": meta["version"], "build": meta["build"],
                             "materialRole": meta["materialRole"], "target": meta["target"],
                             "macArchitectures": architectures,
                             "source": {k: source[k] for k in ("head", "label", "sourceSHA256")},
                             "frozenSource": candidate_source,
                             "frozenReleaseMode": candidate_mode,
                             "materialCheckout": material_source,
                             "fieldLengths": lengths, "submissionReady": not pending,
                             "pending": pending,
                             "recommended": ["optional reviewer demonstration video"] if not meta.get("reviewVideoURL") else [],
                             "ownerActions": "after-membership.txt",
                             "validationScope": "local fields/assets only; no Apple review or real USB proof"}


def check_history(directory):
    """Verify existing frozen bytes, without reinterpreting their build as the current one."""
    directory = Path(directory).resolve()
    for checksum in ("SHA256SUMS", "ZIP-SHA256SUMS"):
        lines = (directory / checksum).read_text().splitlines()
        if not lines:
            raise ValueError("empty historical checksums")
        for line in lines:
            match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
            if not match:
                raise ValueError("invalid historical checksum line")
            path = (directory / match[2]).resolve()
            if not path.is_relative_to(directory) or not path.is_file() or sha(path) != match[1]:
                raise ValueError("historical material checksum mismatch")
    meta = json.loads((directory / "metadata.json").read_text())
    return {"version": meta["version"], "build": meta["build"], "materialRole": "historical-frozen",
            "submissionReady": False, "validationScope": "frozen bytes only; never current submission materials"}


def archive_files(directory, paths, destination):
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(paths):
            entry = zipfile.ZipInfo(str(path.relative_to(directory)), (1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)


def stage(out, meta, inventory, result):
    out = out.resolve()
    if not out.is_relative_to(ROOT / "build"):
        raise ValueError("stage only under repository build/ to avoid touching user/source files")
    if out.exists():
        raise ValueError("output already exists; choose a fresh directory, never overwrite materials")
    out.mkdir(parents=True)
    for path in MATERIALS.rglob("*"):
        if path.is_file():
            target = out / path.relative_to(MATERIALS)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
    shutil.copyfile(ROOT / "docs/PRIVACY.md", out / "public/privacy-policy.md")
    # Public document export links to staged install text rather than missing source-tree paths.
    policy = out / "public/privacy-policy.md"
    policy.write_text(policy.read_text().replace("使用者安装指南.md", "mac-install.txt"))
    (out / "icon").mkdir()
    shutil.copyfile(local_path(inventory["icon"]["path"]), out / "icon/iPad-icon-1024.png")
    (out / "fields").mkdir()
    for lang, loc in meta["localizations"].items():
        folder = out / "fields" / lang
        folder.mkdir()
        for field, value in loc.items():
            (folder / (field + ".txt")).write_text(value + "\n")
        shutil.copyfile(MATERIALS / meta["reviewNotesFiles"][lang], folder / "reviewNotes.txt")
        (folder / "whatToTest.txt").write_text(meta["betaTestInformation"][lang] + "\n")
    for item in meta["approvedStoreScreenshots"]:
        target = out / "screenshots" / Path(item["path"]).name
        target.parent.mkdir(exist_ok=True)
        if target.exists():
            raise ValueError("approved screenshot basename collision")
        shutil.copyfile(local_path(item["path"]), target)
    (out / "validation.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    (out / "PENDING.txt").write_text(("Not submission-ready. Confirm:\n" if result["pending"] else "Local material checks passed; Apple validation remains separate.\n") + "".join(f"- {x}\n" for x in result["pending"]))
    (out / "MATERIALS-MANIFEST.json").write_text(json.dumps({k: result[k] for k in ["version", "build", "materialRole", "target", "macArchitectures", "source", "frozenSource", "materialCheckout", "frozenReleaseMode", "submissionReady"]}, indent=2) + "\n")
    files = [p for p in out.rglob("*") if p.is_file()]
    (out / "SHA256SUMS").write_text("".join(f"{sha(p)}  {p.relative_to(out)}\n" for p in sorted(files)))
    archive_files(out, list((out / "public").iterdir()), out / "PadInk-public-documents-only.zip")
    archive_files(out, files + [out / "SHA256SUMS"], out / "PadInk-store-materials.zip")
    (out / "ZIP-SHA256SUMS").write_text("".join(f"{sha(p)}  {p.name}\n" for p in sorted(out.glob("*.zip"))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--require-ready", action="store_true")
    parser.add_argument("--release", type=Path, help="Bind materials to a checked frozen RC/preview manifest")
    parser.add_argument("--source-root", type=Path, help="Exact clean build checkout; independently record current materials and require identical app input digest")
    parser.add_argument("--history", type=Path, help="Read-only checksum verification of an existing historical material export")
    args = parser.parse_args()
    try:
        if args.history:
            if args.out or args.require_ready or args.release or args.source_root:
                raise ValueError("historical materials cannot be staged or submitted as the current candidate")
            print(json.dumps(check_history(args.history), ensure_ascii=False, indent=2))
            return 0
        meta, inventory, result = validate(release=args.release, source_root=args.source_root)
        if args.out and not args.release:
            raise ValueError("staging requires --release to bind materials to exact frozen inputs")
        if args.require_ready and not args.release:
            raise ValueError("submission-ready checks require --release to identify the exact frozen candidate")
        if args.require_ready and (result["frozenReleaseMode"] != "release-candidate" or result["frozenSource"]["dirty"]):
            raise ValueError("working-tree previews cannot be submitted; freeze a clean release candidate first")
        if args.out:
            stage(args.out, meta, inventory, result)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if args.require_ready and not result["submissionReady"]:
            return 2
        return 0
    except (ValueError, KeyError, OSError) as error:
        print(f"store materials check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
