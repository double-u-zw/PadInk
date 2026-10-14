#!/bin/zsh
# First setup: Xcode, your own signing team, and the wired iPad.
set -uo pipefail
cd "${0:A:h:h:h}"
die() { print -P "\n%F{red}✗ $1%f"; print "按回车键关闭窗口。"; read -r _; exit 1; }
print -P "%BPadInk · 首次设置%b"
print "请保留这整个文件夹：首次安装和每周续期都使用它。"
print "默认安装独立的 PadInk，不覆盖现有 PadInk；首次需要新授权与配对。"
print "这一步准备签名；完成后还需运行“更新 PadInk”安装两端。"
print -P "\n%B▶ 1/3 检查 Xcode%b"
xcodebuild -version > /dev/null 2>&1 || die "没有找到可用的 Xcode。请从 App Store 安装 Xcode，打开一次并完成许可与组件安装。若已安装，请在 Xcode › 设置 › 位置中把命令行工具选为 Xcode。"
xcodebuild -version | head -1
xcodebuild -checkFirstLaunchStatus > /dev/null 2>&1 || die "Xcode 的首次准备尚未完成。请打开 Xcode，完成许可与组件安装后重试。"
xcrun --find devicectl > /dev/null 2>&1 || die "当前 Xcode 没有可用的设备安装工具。请更新 Xcode，并在 Xcode › 设置 › 位置中选中它。"
print -P "%B▶ 2/3 本机签名配置%b"
./engineering/scripts/configure-local-signing.sh || die "签名设置未完成。请按上方具体提示处理后重新运行；无需删除已有 App。"
print -P "%B▶ 3/3 检查 iPad%b"
if udid_msg=$(python3 engineering/scripts/lib/device_check.py 2>&1 >/dev/null); then
 print "$udid_msg"
else
 print -P "%F{yellow}$udid_msg%f"
 print "签名配置已保存。处理上面的 iPad 提示后直接运行“更新 PadInk”，无需重复首次设置。"
fi
print -P "\n%F{green}✓ 签名设置完成。下一步：插线、解锁 iPad，双击“更新 PadInk”。%f"
print "完整操作说明：docs/开发者指南.md。首次安装后还需 iPad 信任开发者、Mac 授权，以及两端确认配对。"
print "按回车键关闭窗口。"; read -r _
