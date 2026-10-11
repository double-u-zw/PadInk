#!/usr/bin/env python3
"""Prepare/check RC provenance; build notarized Mac ZIP and local TestFlight upload candidate.
No App Store Connect upload or publication. Mac notarization submits to Apple's notary service.
A dirty checkout can only create an explicitly unsigned working-tree preview.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from urllib.parse import unquote, urlsplit
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = 1
MAC_ARCHITECTURES = {"arm64", "x86_64"}
PUBLIC_DOCS = ["README.md", "engineering/README.md", *["docs/" + name for name in ["ARCHITECTURE.md", "PROTOCOL.md", "SUPPORT_MATRIX.md", "使用教程.md", "使用者安装指南.md", "开发者指南.md", "RELEASE.md", "PRIVACY.md", "ECRU.md", "AltStore安装说明.txt", "试用验收清单.txt"]]]
METADATA = {"manifest.json", "SHA256SUMS", "ASSETS.json", "RELEASE_NOTES.md"}


class ReleaseError(ValueError):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    # Read-only loading: importlib bytecode caches would change a clean source tree.
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    return module


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def forbidden_source(name):
    path = PurePosixPath(name)
    return (name.startswith(("build/", ".build/", ".git/", ".aws/", "diagnostics/", "evidence/"))
            or path.suffix.lower() in {".log", ".ips"} or path.name.lower().startswith("padink-diagnostics-")
            or ".local.xcconfig" in name or path.suffix.lower() in {".p12", ".pfx", ".p8", ".pem", ".cer", ".crt", ".der", ".key", ".keychain", ".keychain-db", ".mobileprovision", ".ipa"}
            or name in {"SOURCE_COMMIT", "SOURCE_PROVENANCE.json"}
            or any(part.endswith((".xcarchive", ".app")) for part in path.parts))


def source_snapshot(root):
    head = git(root, "rev-parse", "HEAD").decode().strip()
    dirty = bool(git(root, "status", "--porcelain", "--untracked-files=normal"))
    names = sorted(set(git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").decode().split("\0")) - {""})
    files = {}
    for name in names:
        if forbidden_source(name):
            raise ReleaseError(f"源码中出现不允许交付的材料：{name}。请先移出版本控制。")
        path = root / name
        if not path.exists():
            continue  # working-tree preview may include deleted tracked paths
        if path.is_symlink() or not path.is_file():
            raise ReleaseError(f"源码包不接受链接或特殊文件：{name}")
        files[name] = file_sha(path)
    identity = load_module(root / "engineering/scripts/build-identity.py", "padink_build_identity").identity(root)
    if identity["head"] != head:
        raise ReleaseError("构建标识与当前 HEAD 不一致。")
    return {"head": head, "label": identity["label"], "sourceSHA256": identity["sourceSHA256"],
            "treeSHA256": sha(canonical(files)), "dirty": dirty}, files


def read_version(root):
    path = root / "Config/Version.xcconfig"
    if not path.exists():
        raise ReleaseError("缺少 Config/Version.xcconfig，不能猜测 RC 版本。")
    config = parse_config(path)
    version, build = config.get("MARKETING_VERSION", ""), config.get("CURRENT_PROJECT_VERSION", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
        raise ReleaseError("版本应为 x.y.z，build 应为正整数。")
    return version, build


def parse_config(path):
    config = {}
    for line in path.read_text().splitlines():
        line = line.split("//", 1)[0].strip()
        if not line:
            continue
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)\s*=\s*(.+)", line)
        if not match:
            raise ReleaseError(f"不支持的配置语法：{path.name}；只接受 KEY = VALUE。")
        config[match[1]] = match[2].strip().strip('"')
    return config


def prepare(root, out=None, preview=False, notes=None):
    root = Path(root).resolve()
    source, files = source_snapshot(root)
    if source["dirty"] and not preview:
        raise ReleaseError("工作区有未提交改动：不能把旧 HEAD 或 dirty 树宣称正式 RC。请提交后正式 prepare；本轮用 prepare --preview 保留未提交 diff。")
    version, build = read_version(root)
    marker = "UNSIGNED-WORKING-TREE-PREVIEW" if preview else "RC"
    notes_supplied = notes is not None
    if notes_supplied:
        notes_path = Path(notes).resolve()
        if not notes_path.is_file():
            raise ReleaseError("--notes 指定的发布说明不存在。")
        text = notes_path.read_text()
        if not text.strip():
            raise ReleaseError("release notes 不能为空。")
    else:
        text = f"# PadInk {version} build {build} · {marker}\n\n候选准备完成，尚未签名、公证或上传 TestFlight。正式说明待补充。\n\n[安装指南](docs/使用者安装指南.md)\n"
    out = Path(out).resolve() if out else root / "build/rc" / f"PadInk-{version}-b{build}-{marker}-{source['label']}"
    if out.exists() and any(out.iterdir()):
        raise ReleaseError("输出目录非空，不能覆盖已有候选包。请指定新 --out 目录。")
    out.mkdir(parents=True, exist_ok=True)
    name = f"PadInk-{version}-b{build}-{marker}-source.zip"
    prefix = name.removesuffix("-source.zip") + "/"
    with zipfile.ZipFile(out / name, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for relative in files:
            path = root / relative
            entry = zipfile.ZipInfo(prefix + relative, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | (0o755 if os.access(path, os.X_OK) else 0o644)) << 16
            archive.writestr(entry, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr(prefix + "SOURCE_COMMIT", source["head"] + "\n")
        archive.writestr(prefix + "SOURCE_PROVENANCE.json", json.dumps(source, indent=2) + "\n")
    (out / "RELEASE_NOTES.md").write_text(text)
    contract = {"schemaVersion": SCHEMA, "mac": {"role": "end-user-mac", "format": "separate-arm64-and-x86_64-zips-containing-Developer-ID-signed-stapled-app", "architectures": sorted(MAC_ARCHITECTURES), "mustVerify": ["source-and-version", "codesign", "stapler", "Gatekeeper"]},
                "ipad": {"role": "maintainer-upload-only", "format": "app-store-connect-export-ipa", "endUserInstallation": "TestFlight invitation/link after upload, processing and any required review", "ipaIsOrdinaryUserInstaller": False},
                "source": {"role": "developer-source-only", "mustExclude": ["signing-configs", "private-keys-and-certificates", "diagnostics", "build-logs"]},
                "preview": {"unsigned": True, "endUserDistributable": False}}
    (out / "ASSETS.json").write_text(json.dumps(contract, ensure_ascii=False, indent=2) + "\n")
    manifest = {"schemaVersion": SCHEMA, "createdAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                "release": {"version": version, "build": build, "channel": "preview" if preview else "rc", "mode": "unsigned-working-tree-preview" if preview else "release-candidate", "published": False, "variant": "release", "macArchitectures": sorted(MAC_ARCHITECTURES)},
                "source": source, "releaseNotes": {"path": "RELEASE_NOTES.md", "status": "provided" if notes_supplied else "draft"},
                "distribution": {"mac": "unsigned-preview" if preview else "not-built", "ipad": "not-uploaded-to-TestFlight", "endUserDistributable": False},
                "assets": [{"path": name, "role": "developer-source-only", "sha256": file_sha(out / name), "byteCount": (out / name).stat().st_size}],
                "platformValidation": {"mac": "not-performed", "ipad": "not-performed"}}
    write_manifest(out, manifest)
    check(root, out)
    if not preview:
        ensure_frozen(root, manifest)
    return out


def write_manifest(out, manifest):
    for asset in manifest["assets"]:
        path = safe_asset(out, asset["path"])
        asset["sha256"], asset["byteCount"] = file_sha(path), path.stat().st_size
    manifest["releaseNotes"]["sha256"] = file_sha(out / "RELEASE_NOTES.md")
    manifest["assetContractSHA256"] = file_sha(out / "ASSETS.json")
    (out / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    names = sorted((METADATA - {"SHA256SUMS"}) | {asset["path"] for asset in manifest["assets"]})
    (out / "SHA256SUMS").write_text("".join(f"{file_sha(safe_asset(out, name))}  {name}\n" for name in names))


def safe_asset(out, name):
    out = Path(out).resolve()
    parsed = PurePosixPath(name) if isinstance(name, str) else PurePosixPath("..")
    if not isinstance(name, str) or parsed.is_absolute() or ".." in parsed.parts or name in {"", ".", ".."}:
        raise ReleaseError("候选目录只接受根目录内的普通资产文件名。")
    path = out / name
    cursor = out
    for part in parsed.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise ReleaseError("资产路径不接受符号链接。")
    if out not in path.resolve().parents:
        raise ReleaseError("资产路径不能通过链接越界。")
    if path.is_symlink() or not path.is_file():
        raise ReleaseError(f"候选资产缺失或为链接：{name}")
    return path


def check_source_zip(path, source):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ReleaseError("源码 ZIP 有重复条目。")
        prefixes = {PurePosixPath(name).parts[0] for name in names if PurePosixPath(name).parts}
        if len(prefixes) != 1:
            raise ReleaseError("源码 ZIP 必须只有一个根目录。")
        prefix = prefixes.pop() + "/"
        try:
            revision = archive.read(prefix + "SOURCE_COMMIT").decode().strip()
            provenance = json.loads(archive.read(prefix + "SOURCE_PROVENANCE.json"))
        except KeyError:
            raise ReleaseError("源码 ZIP 缺少 RC provenance；普通旧源码包不能替代冻结 RC。")
        if revision != source["head"] or provenance != source:
            raise ReleaseError("源码 ZIP 的 revision/provenance 与候选 manifest 不一致，不能沿用旧 HEAD 包。")
        files = {}
        for name in names:
            relative = name.removeprefix(prefix)
            if relative in {"SOURCE_COMMIT", "SOURCE_PROVENANCE.json"} or name.endswith("/"):
                continue
            if ".." in PurePosixPath(relative).parts or PurePosixPath(relative).is_absolute() or forbidden_source(relative):
                raise ReleaseError(f"源码 ZIP 包含不允许交付的路径：{relative}")
            files[relative] = sha(archive.read(name))
        if sha(canonical(files)) != source["treeSHA256"]:
            raise ReleaseError("源码 ZIP 内容与冻结的完整源码树摘要不一致。")


def check(root, out, require_assets=False, require_distributable=False, verify_platform=False, runner=None):
    out = Path(out).resolve()
    manifest = json.loads(safe_asset(out, "manifest.json").read_text())
    if manifest.get("schemaVersion") != SCHEMA:
        raise ReleaseError("不支持的 RC manifest schema。")
    release, source = manifest["release"], manifest["source"]
    preview = release["mode"] == "unsigned-working-tree-preview"
    if preview != (release["channel"] == "preview") or (source["dirty"] and not preview):
        raise ReleaseError("dirty/preview/RC 标记不一致。")
    if release["published"] or manifest["distribution"]["endUserDistributable"]:
        raise ReleaseError("本地工具尚未核验 TestFlight 发布状态，不能宣称双端已发布或可分发。")
    asset_names = [asset["path"] for asset in manifest["assets"]]
    if len(asset_names) != len(set(asset_names)):
        raise ReleaseError("manifest 包含重复资产。")
    allowed = METADATA | set(asset_names)
    actual = layout_files(out, allowed)
    if actual != allowed:
        raise ReleaseError("候选目录包含缺失或未声明文件；不得放入日志、配置、证书或诊断。")
    sums = {}
    for line in safe_asset(out, "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match[2] in sums:
            raise ReleaseError("SHA256SUMS 格式错误或有重复条目。")
        sums[match[2]] = match[1]
    if set(sums) != allowed - {"SHA256SUMS"}:
        raise ReleaseError("SHA256SUMS 没有完整覆盖候选目录。")
    for name, digest in sums.items():
        if file_sha(safe_asset(out, name)) != digest:
            raise ReleaseError(f"SHA256 不匹配：{name}")
    if manifest["releaseNotes"]["sha256"] != file_sha(out / "RELEASE_NOTES.md") or manifest["assetContractSHA256"] != file_sha(out / "ASSETS.json"):
        raise ReleaseError("notes/assets contract 摘要与 manifest 不一致。")
    contract = json.loads((out / "ASSETS.json").read_text())
    if contract.get("schemaVersion") != SCHEMA or contract.get("ipad", {}).get("ipaIsOrdinaryUserInstaller") is not False or contract.get("preview", {}).get("endUserDistributable") is not False:
        raise ReleaseError("ASSETS 契约必须明确 IPA 不是普通用户安装包、unsigned preview 不可分发。")
    source_assets = [asset for asset in manifest["assets"] if asset["role"] == "developer-source-only"]
    if len(source_assets) != 1:
        raise ReleaseError("必须提供且仅提供一个冻结源码资产。")
    check_source_zip(safe_asset(out, source_assets[0]["path"]), source)
    for asset in manifest["assets"]:
        path = safe_asset(out, asset["path"])
        if asset["sha256"] != file_sha(path) or asset["byteCount"] != path.stat().st_size:
            raise ReleaseError(f"资产摘要/大小不匹配：{path.name}")
        if asset["role"] == "maintainer-testflight-upload-candidate":
            if preview or asset.get("ordinaryUserInstaller") is not False or asset.get("uploadRequired") is not True:
                raise ReleaseError("iPad IPA 只能是维护者上传候选，不能冒充普通用户安装包。")
            verify_ipa_metadata(path, manifest, asset["bundleID"])
        elif asset["role"] == "end-user-mac":
            if asset.get("architecture") not in MAC_ARCHITECTURES or ("-mac-" + str(asset.get("architecture")) + "-") not in asset["path"]:
                raise ReleaseError("Mac asset must declare arm64 or x86_64.")
            if preview or asset.get("signing") != "Developer ID Application" or asset.get("notarization") != "accepted-and-stapled":
                raise ReleaseError("Mac 分发资产缺少明确签名/公证标记。")
        elif asset["role"] != "developer-source-only":
            raise ReleaseError("未知资产角色。")
    mac_assets = [a for a in manifest["assets"] if a["role"] == "end-user-mac"]
    architectures = [a.get("architecture") for a in mac_assets]
    if len(architectures) != len(set(architectures)): raise ReleaseError("Duplicate Mac architecture assets.")
    if require_assets and set(architectures) != MAC_ARCHITECTURES: raise ReleaseError("RC needs both arm64 and x86_64 Mac assets.")
    roles = {asset["role"] for asset in manifest["assets"]}
    if require_assets and any(not asset.get("debugSymbols", {}).get("matchedAtBuild") for asset in manifest["assets"] if asset["role"] != "developer-source-only"):
        raise ReleaseError("正式二进制资产缺少 App/dSYM UUID 匹配记录。")
    if require_assets and (preview or not {"end-user-mac", "maintainer-testflight-upload-candidate"} <= roles or manifest["releaseNotes"]["status"] != "provided"):
        raise ReleaseError("正式 RC 所需 Mac/iPad 资产或 release notes 尚未齐备；预览不是正式资产。")
    independently_verified = False
    if verify_platform or require_distributable:
        for mac in mac_assets:
            verify_mac_zip(root, out / mac["path"], manifest, mac["bundleID"], mac["teamID"], runner, mac["architecture"])
            independently_verified = True
        ipad = next((asset for asset in manifest["assets"] if asset["role"] == "maintainer-testflight-upload-candidate"), None)
        if ipad:
            verify_ipad_export(out / ipad["path"], manifest, ipad["bundleID"], ipad["teamID"], runner or Runner(root, "ipad-independent-check"))
    if require_distributable:
        raise ReleaseError("Mac 本机验签结果不能证明 iPad 已在 TestFlight 可安装；本工具不上传或核验 TestFlight，双端分发保持未完成。")
    return manifest, independently_verified


def ensure_frozen(root, manifest):
    if manifest["release"]["mode"] != "release-candidate":
        raise ReleaseError("unsigned working-tree preview 禁止进入正式签名/公证/TestFlight export。")
    source, _ = source_snapshot(root)
    if source["dirty"] or source != manifest["source"] or read_version(root) != (manifest["release"]["version"], manifest["release"]["build"]):
        raise ReleaseError("源码/版本与已冻结 RC 不一致；请从干净 HEAD 重新 prepare，不能为旧 HEAD 或已改变的树签名。")


def paid_config(root, platform):
    path = root / "Config/Release.local.xcconfig"
    if not path.exists():
        raise ReleaseError("缺少 Config/Release.local.xcconfig。按 Release.example.xcconfig 填写正式付费团队/注册 bundle ID；不会使用免费开发者配置代替。")
    config = parse_config(path)
    required = ["DEVELOPMENT_TEAM", "PADINK_BUNDLE_PREFIX", "PADINK_MAC_BUNDLE_ID", "PADINK_IPAD_BUNDLE_ID"]
    required += ["PADINK_MAC_SIGN_IDENTITY", "PADINK_NOTARY_PROFILE"] if platform == "mac" else ["PADINK_IPAD_SIGN_IDENTITY"]
    if any(not config.get(key) or "YOUR_" in config[key] or "$" in config[key] for key in required):
        raise ReleaseError("正式发布配置缺失或仍有占位符；不会猜测团队、bundle ID 或 credentials。")
    if not re.fullmatch(r"[A-Z0-9]{10}", config["DEVELOPMENT_TEAM"]):
        raise ReleaseError("正式团队 ID 必须为 10 位字母/数字。")
    for key in ["PADINK_BUNDLE_PREFIX", "PADINK_MAC_BUNDLE_ID", "PADINK_IPAD_BUNDLE_ID"]:
        if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", config[key]):
            raise ReleaseError(f"不合法的正式 bundle 标识：{key}")
    if config["PADINK_MAC_BUNDLE_ID"] == config["PADINK_IPAD_BUNDLE_ID"]:
        raise ReleaseError("Mac 与 iPad 需要各自明确的正式 bundle ID。")
    return config


class Runner:
    def __init__(self, root, label):
        timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        self.logs = root / "build/rc-private-logs" / (label + "-" + timestamp)
        self.logs.mkdir(parents=True, exist_ok=True)
        self.index = 0

    def __call__(self, args):
        self.index += 1
        result = subprocess.run([str(arg) for arg in args], capture_output=True)
        log = self.logs / f"{self.index:02d}-{Path(str(args[0])).name}.log"
        log.write_bytes(result.stdout + b"\n" + result.stderr)
        if result.returncode:
            raise ReleaseError(f"{Path(str(args[0])).name} 失败；私有日志：{log}。未形成可分发资产。")
        return result.stdout, result.stderr


def preflight(config, platform, run):
    output, _ = run(["security", "find-identity", "-v", "-p", "codesigning"])
    names = re.findall(r'"([^"\n]+)"', output.decode(errors="replace"))
    identity = config["PADINK_MAC_SIGN_IDENTITY"] if platform == "mac" else config["PADINK_IPAD_SIGN_IDENTITY"]
    team = config["DEVELOPMENT_TEAM"]
    prefix = "Developer ID Application:" if platform == "mac" else "Apple Distribution:"
    if not any(name.startswith(prefix) and f"({team})" in name and (name == identity or identity == "Apple Distribution") for name in names):
        raise ReleaseError(f"钥匙串缺少正式团队可用的 {prefix.rstrip(':')} 私钥身份；免费 Apple Development 不能替代。")
    if platform == "mac":
        run(["xcrun", "notarytool", "history", "--keychain-profile", config["PADINK_NOTARY_PROFILE"], "--output-format", "json"])
    run(["xcodebuild", "-version"])


def build_settings(manifest, config, platform):
    return [f"MARKETING_VERSION={manifest['release']['version']}", f"CURRENT_PROJECT_VERSION={manifest['release']['build']}",
            "PADINK_BUILD_VARIANT=release", "PADINK_RELEASE_CHANNEL=rc", f"PADINK_DISTRIBUTION={'direct' if platform == 'mac' else 'testflight'}",
            f"PADINK_SOURCE_COMMIT={manifest['source']['label']}", f"PADINK_SOURCE_REVISION={manifest['source']['head']}",
            f"PADINK_SOURCE_SHA256={manifest['source']['sourceSHA256']}",
            *[f"{key}={config[key]}" for key in ["DEVELOPMENT_TEAM", "PADINK_BUNDLE_PREFIX", "PADINK_MAC_BUNDLE_ID", "PADINK_IPAD_BUNDLE_ID"]]]


def verify_app_metadata(info, manifest, bundle, platform):
    expected = {"CFBundleShortVersionString": manifest["release"]["version"], "CFBundleVersion": manifest["release"]["build"],
                "CFBundleName": "PadInk", "CFBundleDisplayName": "PadInk", "CFBundleExecutable": "PadInk",
                "CFBundleIdentifier": bundle, "PadInkBuildVariant": "release", "PadInkReleaseChannel": "rc", "PadInkDistribution": "direct" if platform == "mac" else "testflight",
                "PadInkSourceCommit": manifest["source"]["label"], "PadInkSourceRevision": manifest["source"]["head"], "PadInkSourceDigest": manifest["source"]["sourceSHA256"]}
    for key, value in expected.items():
        if str(info.get(key, "")) != value:
            raise ReleaseError(f"{platform} 产物 {key} 与冻结的版本/源码身份不一致。")


def verify_ipa_metadata(path, manifest, bundle):
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(names) != 1:
            raise ReleaseError("iPad 导出应只含一个主 App。")
        if names[0] != "Payload/PadInk.app/Info.plist":
            raise ReleaseError("iPad 导出产物必须名为 PadInk.app。")
        verify_app_metadata(plistlib.loads(archive.read(names[0])), manifest, bundle, "ipad")


def verify_mac_app(app, manifest, bundle, team, run, notarized=True):
    if Path(app).name != "PadInk.app":
        raise ReleaseError("Mac 产物必须名为 PadInk.app。")
    verify_app_metadata(plistlib.loads((app / "Contents/Info.plist").read_bytes()), manifest, bundle, "mac")
    run(["codesign", "--verify", "--deep", "--strict", app])
    output, error = run(["codesign", "-d", "--verbose=4", app])
    details = (output + error).decode(errors="replace")
    if "Authority=Developer ID Application:" not in details or f"TeamIdentifier={team}" not in details or not re.search(r"flags=.*\([^\n)]*runtime", details):
        raise ReleaseError("Mac 产物不是指定团队的 hardened-runtime Developer ID 签名。")
    if notarized:
        run(["xcrun", "stapler", "validate", app])
        run(["spctl", "--assess", "--type", "execute", "--verbose=4", app])


def verify_mac_zip(root, path, manifest, bundle, team, runner=None, architecture=None):
    run = runner or Runner(root, "mac-independent-check-" + (architecture or "universal"))
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            parsed = PurePosixPath(name)
            if parsed.is_absolute() or ".." in parsed.parts:
                raise ReleaseError("Mac ZIP 含不安全路径。")
            entry = archive.getinfo(name)
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = archive.read(name).decode()
                resolved = os.path.normpath(str(parsed.parent / target))
                if target.startswith("/") or resolved.startswith("../"):
                    raise ReleaseError("Mac ZIP 含越界链接。")
    with tempfile.TemporaryDirectory() as temporary:
        destination = Path(temporary)
        run(["ditto", "-x", "-k", path, destination])
        apps = list(destination.glob("*.app"))
        if len(apps) != 1:
            raise ReleaseError("Mac ZIP 必须在根目录包含唯一 App。")
        verify_mac_app(apps[0], manifest, bundle, team, run)
        info = plistlib.loads((apps[0] / "Contents/Info.plist").read_bytes())
        binary = apps[0] / "Contents/MacOS" / info["CFBundleExecutable"]
        output, _ = run(["xcrun", "dwarfdump", "--uuid", binary])
        uuids = parse_uuids(output)
        expected = {architecture} if architecture else MAC_ARCHITECTURES
        if set(uuids) != expected:
            raise ReleaseError("Mac ZIP 的实际架构与资产标签不一致。")
        asset = next((asset for asset in manifest["assets"] if asset["role"] == "end-user-mac" and asset.get("architecture") == architecture), None)
        if asset and asset.get("debugSymbols", {}).get("uuidByArchitecture") != uuids:
            raise ReleaseError("Mac ZIP 的 UUID 与保留的 dSYM 匹配记录不一致。")


def add_asset(out, manifest, asset):
    if any(existing["role"] == asset["role"] and existing.get("architecture") == asset.get("architecture") for existing in manifest["assets"]):
        raise ReleaseError("该平台资产已存在；重新构建请 prepare 到新目录，避免覆写既有候选。")
    manifest["assets"].append(asset)
    write_manifest(out, manifest)


def build_platform(root, out, platform, runner=None, architecture=None):
    if platform == "mac" and architecture is None:
        return [build_platform(root, out, platform, runner, arch) for arch in sorted(MAC_ARCHITECTURES)]
    if platform == "mac" and architecture not in MAC_ARCHITECTURES:
        raise ReleaseError("Mac architecture must be arm64 or x86_64.")
    if platform != "mac" and architecture is not None:
        raise ReleaseError("Architecture selector applies only to Mac.")
    root, out = Path(root).resolve(), Path(out).resolve()
    manifest, _ = check(root, out)
    ensure_frozen(root, manifest)
    role = "end-user-mac" if platform == "mac" else "maintainer-testflight-upload-candidate"
    if any(asset["role"] == role and asset.get("architecture") == architecture for asset in manifest["assets"]):
        raise ReleaseError("该平台候选资产已生成；请用新目录准备另一候选。")
    config = paid_config(root, platform)
    release_identity = {key: config[key] for key in ["DEVELOPMENT_TEAM", "PADINK_BUNDLE_PREFIX", "PADINK_MAC_BUNDLE_ID", "PADINK_IPAD_BUNDLE_ID"]}
    if manifest.get("releaseIdentity", release_identity) != release_identity:
        raise ReleaseError("Release.local 的正式团队/bundle ID 与已生成的另一端不一致；请用新目录准备候选。")
    manifest["releaseIdentity"] = release_identity
    run = runner or Runner(root, platform + ("-" + architecture if architecture else ""))
    preflight(config, platform, run)  # fails before producing assets if paid identities/profile are unavailable
    run([sys.executable, root / "engineering/scripts/generate-project.py"])
    ensure_frozen(root, manifest)
    work = root / "build/rc-private-work" / (out.name + "-" + platform + ("-" + architecture if architecture else ""))
    if work.exists():
        raise ReleaseError(f"私有工作目录已存在：{work}。保留日志后清理，或选择新的 --out。")
    work.mkdir(parents=True)
    archive = work / ("PadInkMac.xcarchive" if platform == "mac" else "PadInkPad.xcarchive")
    args = ["xcodebuild", "-project", root / "PadInk.xcodeproj", "-scheme", "PadInkMac" if platform == "mac" else "PadInkPad",
            "-configuration", "Release", "-destination", "generic/platform=macOS" if platform == "mac" else "generic/platform=iOS",
            "-derivedDataPath", work / "DerivedData", "-archivePath", archive, "-allowProvisioningUpdates", "archive",
            *build_settings(manifest, config, platform), "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym", "ONLY_ACTIVE_ARCH=NO"]
    args += [f"CODE_SIGN_IDENTITY={config['PADINK_MAC_SIGN_IDENTITY']}", "CODE_SIGN_STYLE=Manual", "ENABLE_HARDENED_RUNTIME=YES", "ARCHS=" + architecture] if platform == "mac" else ["CODE_SIGN_IDENTITY=Apple Development", "CODE_SIGN_STYLE=Automatic", "ARCHS=arm64"]
    run(args)
    apps = list((archive / "Products/Applications").glob("*.app"))
    if len(apps) != 1 or apps[0].name != "PadInk.app":
        raise ReleaseError("Xcode archive 必须含唯一的 PadInk.app。")
    app = apps[0]
    symbols = verify_debug_symbols(archive, app, platform, run, architecture)
    version, build = manifest["release"]["version"], manifest["release"]["build"]
    team, bundle = config["DEVELOPMENT_TEAM"], config["PADINK_MAC_BUNDLE_ID" if platform == "mac" else "PADINK_IPAD_BUNDLE_ID"]
    if platform == "mac":
        run(["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", config["PADINK_MAC_SIGN_IDENTITY"],
             "--entitlements", root / "Hosts/Mac/PadInkMac.entitlements", app])
        verify_mac_app(app, manifest, bundle, team, run, notarized=False)
        submission = work / "notary-submission.zip"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission])
        output, _ = run(["xcrun", "notarytool", "submit", submission, "--keychain-profile", config["PADINK_NOTARY_PROFILE"], "--wait", "--output-format", "json"])
        receipt = json.loads(output)
        if receipt.get("status") != "Accepted" or not receipt.get("id"):
            raise ReleaseError("Apple 公证未 Accepted；不创建可分发 ZIP。详情保留在私有日志。")
        run(["xcrun", "stapler", "staple", app])
        verify_mac_app(app, manifest, bundle, team, run)
        name = f"PadInk-{version}-b{build}-mac-{architecture}-DeveloperID-notarized.zip"
        candidate = work / name
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, candidate])  # ZIP only after stapling the App
        ensure_frozen(root, manifest)
        verify_mac_zip(root, candidate, manifest, bundle, team, run, architecture)
        shutil.copy2(candidate, out / name)
        manifest["distribution"]["mac"] = "Developer-ID-notarized-and-stapled-split-zips" if {architecture} | {a.get("architecture") for a in manifest["assets"] if a["role"] == role} == MAC_ARCHITECTURES else "partial-architecture-assets"
        manifest["platformValidation"]["mac"] = "codesign-stapler-Gatekeeper-passed-at-build"
        asset = {"path": name, "role": role, "bundleID": bundle, "teamID": team, "signing": "Developer ID Application", "notarization": "accepted-and-stapled", "notarySubmissionID": receipt["id"], "architecture": architecture}
    else:
        verify_app_metadata(plistlib.loads((app / "Info.plist").read_bytes()), manifest, bundle, "ipad")
        options = work / "ExportOptions.plist"
        options.write_bytes(plistlib.dumps({"method": "app-store-connect", "destination": "export", "teamID": team,
                                          "signingStyle": "automatic", "signingCertificate": "Apple Distribution", "manageAppVersionAndBuildNumber": False,
                                          "uploadSymbols": True, "stripSwiftSymbols": True}))
        export = work / "export"
        run(["xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", export, "-exportOptionsPlist", options, "-allowProvisioningUpdates"])
        ipas = list(export.glob("*.ipa"))
        if len(ipas) != 1:
            raise ReleaseError("App Store Connect export 缺少唯一 IPA。")
        verify_ipa_metadata(ipas[0], manifest, bundle)
        verify_ipad_export(ipas[0], manifest, bundle, team, run)
        ensure_frozen(root, manifest)
        name = f"PadInk-{version}-b{build}-ipad-TestFlight-upload-candidate.ipa"
        shutil.copy2(ipas[0], out / name)
        manifest["platformValidation"]["ipad"] = "Apple-Distribution-signature-and-AppStore-profile-passed-at-export; TestFlight-not-uploaded"
        asset = {"path": name, "role": role, "bundleID": bundle, "teamID": team, "signing": "Apple Distribution", "ordinaryUserInstaller": False, "uploadRequired": True}
    asset["debugSymbols"] = symbols
    add_asset(out, manifest, asset)
    check(root, out)
    return out / name



def parse_uuids(output):
    values = dict((architecture, identifier.upper()) for identifier, architecture in re.findall(r"UUID: ([A-Fa-f0-9-]{36}) \(([^)]+)\)", output.decode(errors="replace")))
    if not values:
        raise ReleaseError("dwarfdump 没有返回有效 UUID。")
    return values


def verify_debug_symbols(archive, app, platform, run, architecture=None):
    info = plistlib.loads((app / ("Contents/Info.plist" if platform == "mac" else "Info.plist")).read_bytes())
    binary = app / ("Contents/MacOS" if platform == "mac" else ".") / info["CFBundleExecutable"]
    dsym = archive / "dSYMs" / (app.name + ".dSYM")
    if not dsym.is_dir():
        raise ReleaseError("正式 archive 缺少 App dSYM，不能作为 RC 资产。")
    executable, _ = run(["xcrun", "dwarfdump", "--uuid", binary])
    symbols, _ = run(["xcrun", "dwarfdump", "--uuid", dsym])
    executable, symbols = parse_uuids(executable), parse_uuids(symbols)
    expected = ({architecture} if architecture else MAC_ARCHITECTURES) if platform == "mac" else {"arm64"}
    if set(executable) != expected or executable != symbols:
        raise ReleaseError("App 架构/UUID 与 dSYM 不匹配，不能生成 RC。")
    return {"matchedAtBuild": True, "archiveRetainedPrivately": True, "uuidByArchitecture": executable}


def verify_ipad_export(path, manifest, bundle, team, run):
    with tempfile.TemporaryDirectory() as temporary:
        destination = Path(temporary)
        run(["ditto", "-x", "-k", path, destination])
        apps = list((destination / "Payload").glob("*.app"))
        if len(apps) != 1 or apps[0].name != "PadInk.app":
            raise ReleaseError("iPad IPA 必须含唯一的 Payload/PadInk.app。")
        app = apps[0]
        verify_app_metadata(plistlib.loads((app / "Info.plist").read_bytes()), manifest, bundle, "ipad")
        run(["codesign", "--verify", "--deep", "--strict", app])
        output, error = run(["codesign", "-d", "--verbose=4", app])
        details = (output + error).decode(errors="replace")
        if "Authority=Apple Distribution:" not in details or f"TeamIdentifier={team}" not in details:
            raise ReleaseError("iPad 导出不是指定正式团队的 Apple Distribution 签名。")
        output, _ = run(["security", "cms", "-D", "-i", app / "embedded.mobileprovision"])
        profile = plistlib.loads(output)
        entitlements = profile.get("Entitlements", {})
        if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices") or entitlements.get("get-task-allow") is not False or entitlements.get("application-identifier") != team + "." + bundle:
            raise ReleaseError("iPad 导出不是明确匹配正式 bundle 的 App Store profile，不能冒充 TestFlight 候选。")
        output, _ = run(["xcrun", "dwarfdump", "--uuid", app / plistlib.loads((app / "Info.plist").read_bytes())["CFBundleExecutable"]])
        uuids = parse_uuids(output)
        asset = next((asset for asset in manifest["assets"] if asset["role"] == "maintainer-testflight-upload-candidate"), None)
        if set(uuids) != {"arm64"} or (asset and asset.get("debugSymbols", {}).get("uuidByArchitecture") != uuids):
            raise ReleaseError("iPad 导出 App 的架构/UUID 与 dSYM 匹配记录不一致。")
        expiry = profile.get("ExpirationDate")
        if not expiry or expiry.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
            raise ReleaseError("iPad App Store profile 已过期或缺少有效期。")


def public_assets(root, release, out, include_source=False, runner=None):
    release, out = Path(release).resolve(), Path(out).resolve()
    manifest, _ = check(root, release, require_assets=True, verify_platform=True, runner=runner)
    if out.exists() and any(out.iterdir()):
        raise ReleaseError("公开 staging 目录非空，不能覆盖。")
    out.mkdir(parents=True, exist_ok=True)
    assets = [dict(asset) for asset in manifest["assets"] if asset["role"] == "end-user-mac" or (include_source and asset["role"] == "developer-source-only")]
    for asset in assets:
        shutil.copy2(release / asset["path"], out / asset["path"])
    source = next(asset for asset in manifest["assets"] if asset["role"] == "developer-source-only")
    with zipfile.ZipFile(release / source["path"]) as archive:
        prefix = PurePosixPath(archive.namelist()[0]).parts[0] + "/"
        for relative in PUBLIC_DOCS:
            try:
                data = archive.read(prefix + relative)
            except KeyError:
                raise ReleaseError(f"冻结源码缺少公开使用文档：{relative}，请补齐后重新 prepare。")
            target = out / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            assets.append({"path": relative, "role": "public-documentation", "sha256": file_sha(target), "byteCount": target.stat().st_size})
    notes = (release / "RELEASE_NOTES.md").read_text()
    notes = re.sub(r"(\]\()(?!https?://)([A-Za-z_\u4e00-\u9fff][^/#)]+\.md)(#[^)]*)?(\))",
                   lambda match: match[1] + "docs/" + match[2] + (match[3] or "") + match[4]
                   if "docs/" + match[2] in PUBLIC_DOCS else match[0], notes)
    (out / "RELEASE_NOTES.md").write_text(notes)
    contract = {"schemaVersion": SCHEMA, "kind": "public-download-stage", "ipaIncluded": False, "archiveOrLogsIncluded": False,
                "ipadInstallation": "TestFlight after upload, processing and required review; no TestFlight link verified here"}
    (out / "ASSETS.json").write_text(json.dumps(contract, indent=2) + "\n")
    public = {"schemaVersion": SCHEMA, "kind": "public-download-stage", "release": manifest["release"], "source": manifest["source"],
              "distribution": manifest["distribution"], "assets": assets, "testflightLink": None,
              "note": "Local staging only, not published. No private IPA, archive, signing config or logs included."}
    (out / "PUBLIC-MANIFEST.json").write_text(json.dumps(public, indent=2) + "\n")
    names = sorted({"PUBLIC-MANIFEST.json", "ASSETS.json", "RELEASE_NOTES.md"} | {asset["path"] for asset in assets})
    (out / "SHA256SUMS").write_text("".join(f"{file_sha(safe_asset(out, name))}  {name}\n" for name in names))
    check_public(root, out)
    return out


def check_public(root, out, verify_platform=False, runner=None):
    out = Path(out).resolve()
    manifest = json.loads(safe_asset(out, "PUBLIC-MANIFEST.json").read_text())
    if manifest.get("schemaVersion") != SCHEMA or manifest.get("kind") != "public-download-stage" or manifest["release"]["mode"] != "release-candidate":
        raise ReleaseError("不是正式 RC 的公开 staging 契约。")
    if manifest["release"]["published"] or manifest["distribution"]["endUserDistributable"] or manifest.get("testflightLink"):
        raise ReleaseError("本工具没有核验发布/真实 TestFlight 链接，不能添加该分发声明。")
    roles = [asset["role"] for asset in manifest["assets"]]
    mac_assets = [a for a in manifest["assets"] if a["role"] == "end-user-mac"]
    if {a.get("architecture") for a in mac_assets} != MAC_ARCHITECTURES or len(mac_assets) != 2 or any(role not in {"end-user-mac", "developer-source-only", "public-documentation"} for role in roles):
        raise ReleaseError("公开目录必须包含两种架构的 Mac 资产，可选一个源码资产；不得包含 IPA。")
    expected = {"PUBLIC-MANIFEST.json", "SHA256SUMS", "ASSETS.json", "RELEASE_NOTES.md"} | {asset["path"] for asset in manifest["assets"]}
    if layout_files(out, expected) != expected or any(path.suffix.lower() == ".ipa" for path in out.rglob("*")):
        raise ReleaseError("公开目录有未声明文件或私有 IPA。")
    docs = {asset["path"] for asset in manifest["assets"] if asset["role"] == "public-documentation"}
    if docs != set(PUBLIC_DOCS):
        raise ReleaseError("公开目录必须包含完整的安装、支持、隐私和分发文档。")
    validate_public_links(out, PUBLIC_DOCS + ["RELEASE_NOTES.md"])
    contract = json.loads((out / "ASSETS.json").read_text())
    if contract.get("ipaIncluded") is not False or contract.get("archiveOrLogsIncluded") is not False:
        raise ReleaseError("公开契约必须明确不携带 IPA/archive/日志。")
    sums = {}
    for line in safe_asset(out, "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match[2] in sums:
            raise ReleaseError("公开 SHA256SUMS 格式错误。")
        sums[match[2]] = match[1]
    if set(sums) != expected - {"SHA256SUMS"}:
        raise ReleaseError("公开 SHA256SUMS 未覆盖所有资产。")
    for name, digest in sums.items():
        if file_sha(safe_asset(out, name)) != digest:
            raise ReleaseError(f"公开资产 SHA256 不匹配：{name}")
    for asset in manifest["assets"]:
        path = safe_asset(out, asset["path"])
        if asset["sha256"] != file_sha(path) or asset["byteCount"] != path.stat().st_size:
            raise ReleaseError("公开 manifest 的资产摘要/大小不匹配。")
        if asset["role"] == "developer-source-only":
            check_source_zip(path, manifest["source"])
        elif asset["role"] == "public-documentation":
            if asset["path"] not in PUBLIC_DOCS:
                raise ReleaseError("未知公开使用文档路径。")
        elif asset.get("signing") != "Developer ID Application" or asset.get("notarization") != "accepted-and-stapled":
            raise ReleaseError("公开 Mac 资产没有签名/公证契约。")
        elif verify_platform:
            verify_mac_zip(root, path, manifest, asset["bundleID"], asset["teamID"], runner, asset["architecture"])
    return manifest



def layout_files(out, expected):
    allowed_dirs = {str(parent) for name in expected for parent in PurePosixPath(name).parents if str(parent) != "."}
    files = set()
    for path in out.rglob("*"):
        relative = str(path.relative_to(out))
        if path.is_symlink():
            raise ReleaseError("候选/公开目录不接受文件或目录链接。")
        if path.is_file():
            files.add(relative)
        elif not path.is_dir() or relative not in allowed_dirs:
            raise ReleaseError("候选目录有未声明目录或特殊文件。")
    return files


def validate_public_links(out, documents):
    for relative in documents:
        path = safe_asset(out, relative)
        for target in re.findall(r"\]\(([^\s)]+)", path.read_text()):
            parts = urlsplit(target)
            if parts.scheme or not parts.path or not parts.path.endswith(".md"):
                continue
            target_path = (path.parent / unquote(parts.path)).resolve()
            if out not in target_path.parents or not target_path.is_file():
                raise ReleaseError(f"公开文档链接无目标：{relative} → {target}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    commands = parser.add_subparsers(dest="command", required=True)
    prep = commands.add_parser("prepare")
    prep.add_argument("--preview", action="store_true")
    prep.add_argument("--out", type=Path)
    prep.add_argument("--notes", type=Path)
    checker = commands.add_parser("check")
    checker.add_argument("release", type=Path)
    checker.add_argument("--require-assets", action="store_true")
    checker.add_argument("--require-distributable", action="store_true")
    checker.add_argument("--verify-platform", action="store_true", help="Independently validate Mac ZIP signature, ticket and Gatekeeper")
    for platform in ("mac", "ipad"):
        command = commands.add_parser(platform)
        command.add_argument("--release", type=Path, required=True)
        if platform == "mac": command.add_argument("--arch", choices=["all", "arm64", "x86_64"], default="all")
    public = commands.add_parser("public-assets")
    public.add_argument("--release", type=Path, required=True)
    public.add_argument("--out", type=Path, required=True)
    public.add_argument("--include-source", action="store_true")
    public_check = commands.add_parser("check-public")
    public_check.add_argument("release", type=Path)
    public_check.add_argument("--verify-platform", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            path = prepare(args.root, args.out, args.preview, args.notes)
            print(f"已准备候选契约：{path}\n未发布；预览不供普通用户安装，正式资产尚需签名/公证与 TestFlight。")
        elif args.command == "check":
            manifest, verified = check(args.root, args.release, args.require_assets, args.require_distributable, args.verify_platform)
            print(f"完整性与源码契约通过：{manifest['release']['mode']}。")
            print("Mac 当前独立验签：" + ("codesign/stapler/Gatekeeper 通过" if verified else "未执行；hash 完整性不代表签名或公证通过"))
            print("双端分发：尚未完成；iPad TestFlight 未上传/未核验。")
        elif args.command == "public-assets":
            path = public_assets(args.root, args.release, args.out, args.include_source)
            print(f"公开文件已隔离暂存：{path}；不含 IPA 或私有 archive/日志，未发布。")
        elif args.command == "check-public":
            check_public(args.root, args.release, args.verify_platform)
            print("公开目录完整性/角色契约通过；未发布，TestFlight 安装状态仍需实际核验。")
            print("Mac 当前独立验签：" + ("codesign/stapler/Gatekeeper 通过" if args.verify_platform else "未执行；hash 完整性不代表签名或公证通过"))
        else:
            path = build_platform(args.root, args.release, args.command, architecture=None if args.command == "ipad" or args.arch == "all" else args.arch)
            print(f"已生成本地产物：{path}")
            print("iPad IPA 仅供维护者上传 App Store Connect；本命令不上传、不发布。" if args.command == "ipad" else "Mac 已在本机通过签名、公证票据和 Gatekeeper 检查；未发布下载链接。")
        return 0
    except (ReleaseError, OSError, subprocess.CalledProcessError, KeyError, json.JSONDecodeError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print("RC 操作停止：" + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
