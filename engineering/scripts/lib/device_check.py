#!/usr/bin/env python3
"""Find the one wired, paired, unlocked-enough iPad for installation. Prints its UDID on stdout,
or a Chinese explanation on stderr with a non-zero exit (docs/开发者指南.md)."""
import json, subprocess, sys, tempfile, os
def fail(message, code):
    print(message, file=sys.stderr); sys.exit(code)
with tempfile.TemporaryDirectory() as tmp:
    out = os.path.join(tmp, "devices.json")
    run = subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", out], capture_output=True, text=True)
    if run.returncode != 0 or not os.path.exists(out):
        fail("无法读取设备列表：请确认已安装 Xcode 并至少打开过一次（xcrun devicectl 不可用）。", 10)
    devices = json.load(open(out)).get("result", {}).get("devices", [])
ipads = [d for d in devices if d.get("hardwareProperties", {}).get("reality") == "physical" and d.get("hardwareProperties", {}).get("deviceType") == "iPad"]
if not ipads:
    fail("没有检测到 iPad。请用数据线连接 iPad，并在 iPad 上点“信任此电脑”。", 11)
wired = [d for d in ipads if d.get("connectionProperties", {}).get("transportType") == "wired"]
if not wired:
    fail("iPad 没有通过数据线连接（目前只在局域网中可见）。请插上数据线并解锁 iPad。", 12)
if len(wired) > 1:
    fail("检测到多台用数据线连接的 iPad。请只保留要安装的那一台。", 13)
d = wired[0]; cp = d.get("connectionProperties", {}); dp = d.get("deviceProperties", {})
if cp.get("pairingState") != "paired":
    fail("iPad 还没有信任这台电脑。请解锁 iPad，在弹窗中点“信任”，然后重试。", 14)
if dp.get("developerModeStatus") not in ("enabled", None):
    fail("iPad 的开发者模式未打开：设置 › 隐私与安全性 › 开发者模式，打开后按提示重启 iPad。", 15)
print(d["hardwareProperties"]["udid"])
print(f'{dp.get("name","iPad")} · iPadOS {dp.get("osVersionNumber","?")}', file=sys.stderr)
