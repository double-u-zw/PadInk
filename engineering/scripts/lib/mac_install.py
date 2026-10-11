#!/usr/bin/env python3
"""Install PadInk.app with a reversible rename; finalize only after checking settings/pairing.

This tool never reads or changes Keychain, TCC, preferences or paired-device records.
The bundle ID and signing team must remain unchanged. A successful launch alone does
not prove state preservation: the caller must verify it before using finalize.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

APP_NAME = "PadInk.app"
LEGACY_APP_NAME = "PadInk 0.3.app"
APP_NAMES = {"PadInk.app", "PadInk Dev.app"}

def names(value):
    name = value.get("appName", APP_NAME)
    if name not in APP_NAMES: raise InstallError("安装记录的 App 名称无效。")
    return name, LEGACY_APP_NAME if name == APP_NAME else "PadInk Dev 0.3.app"
OLDER_BUNDLE_ID = "app.padink.greenfield.mac"


class InstallError(ValueError):
    pass


def run(args, check=True):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if check and result.returncode:
        raise InstallError(f"{args[0]} 失败：{result.stderr.strip() or result.stdout.strip()}")
    return result


def app_metadata(app):
    app = Path(app)
    if app.is_symlink():
        raise InstallError(f"应用路径是符号链接，未替换：{app}")
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    bundle, executable = info.get("CFBundleIdentifier", ""), info.get("CFBundleExecutable", "")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle) or not executable or Path(executable).name != executable:
        raise InstallError(f"应用身份或可执行文件名无效：{app}")
    binary = app / "Contents/MacOS" / executable
    return {"bundleID": bundle, "executable": executable,
            "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest()}


def app_identity(app, verify=False):
    metadata = app_metadata(app)
    if verify:
        run(["codesign", "--verify", "--deep", "--strict", app])
    result = run(["codesign", "-d", "--verbose=4", app])
    match = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", result.stdout + "\n" + result.stderr, re.M)
    if not match:
        raise InstallError(f"应用没有有效签名团队，未替换：{app}")
    return dict(metadata, teamID=match[1])


def directory_identity(path):
    info = Path(path).stat()
    return {"device": info.st_dev, "inode": info.st_ino}


def same_owner(identity, expected):
    return all(identity[key] == expected[key] for key in ("bundleID", "teamID"))


def running(app, identity):
    executable = str((Path(app) / "Contents/MacOS" / identity["executable"]).resolve())
    output = run(["ps", "-ax", "-o", "pid=", "-o", "comm="]).stdout
    return any(len(parts := line.strip().split(None, 1)) == 2 and parts[1] == executable for line in output.splitlines())


def wait_for(predicate, timeout=10):
    until = time.monotonic() + timeout
    while True:
        if predicate():
            return
        if time.monotonic() >= until:
            raise InstallError("应用启动或退出验证超时。")
        time.sleep(0.2)


def quit_apps(apps, known=None):
    known = known or {}
    identities = [(Path(app), known[str(app)] if str(app) in known else app_identity(app)) for app in apps if Path(app).exists()]
    for bundle in sorted({identity["bundleID"] for _, identity in identities}):
        run(["osascript", "-e", f'if application id {json.dumps(bundle)} is running then tell application id {json.dumps(bundle)} to quit'], check=False)
    wait_for(lambda: not any(running(app, identity) for app, identity in identities))


def launch(app, identity):
    run(["open", "-n", app])
    wait_for(lambda: running(app, identity))


def save(receipt, value):
    receipt = Path(receipt)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    receipt.chmod(0o600)


def load(receipt):
    value = json.loads(Path(receipt).read_text())
    names(value)
    destination, stage = Path(value["destination"]), Path(value["staging"])
    if value.get("schemaVersion") != 1 or stage.parent != destination or not stage.name.startswith(".PadInk-update.") or stage.is_symlink():
        raise InstallError("迁移记录无效，未删除任何应用。")
    return value


def rollback(receipt, value=None):
    value = value or load(receipt)
    if value["status"] in ("finalized", "rolled-back"):
        raise InstallError("该迁移已完成或已回滚。")
    destination, stage = Path(value["destination"]), Path(value["staging"])
    app_name, legacy_name = names(value)
    target, legacy, backup = destination / app_name, destination / legacy_name, stage / "previous.app"
    installed = value["status"] != "prepared" or backup.exists()
    damaged, known = False, {}
    if installed and target.exists():
        try:
            identity = app_identity(target)
        except InstallError as error:
            # A broken signature must not prevent recovery. The staging directory
            # retains its inode through rename. Require that exact transaction
            # directory and bundle metadata, and preserve all failed App bytes.
            metadata = app_metadata(target)
            belongs = directory_identity(target) == value.get("installedDirectory")
            if not belongs or any(metadata[key] != value["identity"][key] for key in ("bundleID", "executable")):
                raise InstallError("无法确认故障应用属于本次迁移，未改动；请保留迁移目录。") from error
            damaged = True
        else:
            if identity != value["identity"]:
                raise InstallError("已安装应用在迁移后改变，未自动处理；请保留迁移目录。")
        known[str(target)] = value["identity"]
    if backup.exists() and app_identity(backup) != value["previous"]:
        raise InstallError("旧应用备份已改变，未自动恢复；请保留迁移目录。")
    apps = [target]
    if value["legacy"] and legacy.exists():
        if app_identity(legacy) != value["legacy"]:
            raise InstallError("旧名应用在迁移后改变，未自动处理；请保留迁移目录。")
        apps.append(legacy)
        known[str(legacy)] = value["legacy"]
    quit_apps(apps, known)
    if installed:
        if target.exists():
            if damaged:
                failed = stage / "failed-new.app"
                if failed.exists():
                    raise InstallError("已有故障应用样本，未覆盖；请保留迁移目录。")
                os.replace(target, failed)
                value["failedAppRetained"] = str(failed)
            else:
                shutil.rmtree(target)
    if backup.exists():
        os.replace(backup, target)
    if not damaged:
        shutil.rmtree(stage)
    value["status"] = "rolled-back"
    save(receipt, value)
    previous = legacy if value["legacy"] else target if value["previous"] else None
    if previous and previous.exists():
        launch(previous, app_identity(previous))


def install(source, destination, receipt):
    source, destination, receipt = Path(source).absolute(), Path(destination).resolve(), Path(receipt).absolute()
    if source.name not in APP_NAMES:
        raise InstallError("新构建产物必须名为 PadInk.app 或 PadInk Dev.app。")
    if receipt.exists():
        raise InstallError("迁移记录已存在；请先完成或回滚原迁移，不覆盖恢复信息。")
    app_name, legacy_name = names({"appName":source.name})
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if app_name == "PadInk Dev.app" and (info.get("PadInkBuildVariant") != "development" or not info.get("CFBundleIdentifier", "").endswith(".development")):
        raise InstallError("PadInk Dev 必须使用独立开发版身份。")
    if app_name == "PadInk.app" and info.get("PadInkBuildVariant") == "development":
        raise InstallError("开发版不能以正式版名称安装。")
    identity = app_identity(source, verify=True)
    destination.mkdir(parents=True, exist_ok=True)
    target, legacy = destination / app_name, destination / legacy_name
    existing = {}
    for app in (target, legacy):
        if app.exists() or app.is_symlink():
            old = app_identity(app)
            older_padink = app == target and old["bundleID"] == OLDER_BUNDLE_ID and old["teamID"] == identity["teamID"]
            if not same_owner(old, identity) and not older_padink:
                raise InstallError(f"{app.name} 的 bundle ID 或签名团队不同，已有版本仍保留。")
            existing[app.name] = old
    if existing.get(app_name, {}).get("bundleID") == OLDER_BUNDLE_ID and legacy_name not in existing:
        raise InstallError("PadInk.app 是旧产品身份；缺少同身份的 PadInk 0.3.app 迁移基准，已有版本仍保留。")
    stage = Path(tempfile.mkdtemp(prefix=".PadInk-update.", dir=destination))
    value = {"schemaVersion": 1, "status": "prepared", "destination": str(destination), "staging": str(stage),
             "appName": app_name, "identity": identity, "previous": existing.get(app_name), "legacy": existing.get(legacy_name)}
    try:
        run(["ditto", source, stage / app_name])
        if app_identity(stage / app_name, verify=True) != identity:
            raise InstallError("复制后的 Mac 应用身份改变，已有版本仍保留。")
        value["installedDirectory"] = directory_identity(stage / app_name)
        save(receipt, value)
        quit_apps([target, legacy])
        if target.exists():
            os.replace(target, stage / "previous.app")
        os.replace(stage / app_name, target)
        value["status"] = "installed"
        save(receipt, value)
        if app_identity(target, verify=True) != identity:
            raise InstallError("已安装应用验证失败。")
        launch(target, identity)
        value["status"] = "launched-awaiting-state-confirmation"
        save(receipt, value)
        return value
    except Exception as error:
        try:
            if receipt.exists():
                rollback(receipt, value)
            else:
                shutil.rmtree(stage)
        except Exception as recovery:
            raise InstallError(f"{error}；回滚未完成：{recovery}。旧版本备份仍在 {stage}，请保留。") from error
        retained = f'故障新 App 保留在 {value["failedAppRetained"]}。' if value.get("failedAppRetained") else ""
        raise InstallError(f"{error}；已有版本仍保留，安装已回滚。{retained}") from error


def finalize(receipt, confirmed=False):
    value = load(receipt)
    if not confirmed:
        raise InstallError("请先确认新 PadInk 的设置、已配对设备和实际连接保持，再使用 --confirm-state-preserved；旧版本仍保留。")
    if value["status"] != "launched-awaiting-state-confirmation":
        raise InstallError("迁移尚未完成启动验证，或已经结束。")
    destination, stage = Path(value["destination"]), Path(value["staging"])
    app_name, legacy_name = names(value)
    target, legacy, backup = destination / app_name, destination / legacy_name, stage / "previous.app"
    if app_identity(target, verify=True) != value["identity"] or not running(target, value["identity"]):
        raise InstallError("新 PadInk 身份或运行路径验证失败，旧版本仍保留。")
    for app, expected in ((legacy, value["legacy"]), (backup, value["previous"])):
        if expected and (not app.exists() or app_identity(app) != expected):
            raise InstallError("旧应用已改变，未清理迁移备份。")
    if value["legacy"]:
        shutil.rmtree(legacy)
    shutil.rmtree(stage)
    value["status"], value["settingsAndPairingPreserved"] = "finalized", True
    save(receipt, value)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    installer = sub.add_parser("install")
    installer.add_argument("--source", required=True, type=Path)
    installer.add_argument("--destination-dir", type=Path, default=Path("/Applications"))
    for command in (installer, sub.add_parser("finalize"), sub.add_parser("rollback")):
        command.add_argument("--receipt", required=True, type=Path)
    sub.choices["finalize"].add_argument("--confirm-state-preserved", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "install":
            value = install(args.source, args.destination_dir, args.receipt)
            print(f'Mac 应用已验证并启动：{value["destination"]}/{names(value)[0]}；旧版本保留至设置/配对确认。')
        elif args.command == "finalize":
            finalize(args.receipt, args.confirm_state_preserved)
            print("设置与配对已确认，旧名应用及迁移备份已清理。")
        else:
            rollback(args.receipt)
            print("Mac 应用已回滚，旧版本与设置/配对记录保留。")
            if (failed := load(args.receipt).get("failedAppRetained")):
                print(f"故障新 App 保留在 {failed}，供后续检查。")
        return 0
    except (InstallError, OSError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
