#!/bin/zsh
# Update the Mac app and prepare an AltStore IPA; explicit Xcode mode preserves legacy installs.
set -uo pipefail
cd "${0:A:h:h:h}"
variant=${PADINK_BUILD_VARIANT:-development}
[[ "$variant" == development || "$variant" == release ]] || { print "PADINK_BUILD_VARIANT must be development or release"; exit 1; }
app_name=PadInk; [[ "$variant" != development ]] || app_name="PadInk"
default_installer=xcode; [[ "$variant" != development ]] || default_installer=altstore
ipad_installer=${PADINK_IPAD_INSTALLER:-$default_installer}
[[ "$ipad_installer" == altstore || "$ipad_installer" == xcode ]] || { print "PADINK_IPAD_INSTALLER must be altstore or xcode"; exit 1; }
distribution=developer; [[ "$ipad_installer" != altstore ]] || distribution=altstore
channel=development; [[ "$variant/$ipad_installer" != release/altstore ]] || channel=rc
log_dir="build/update/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$log_dir"
step() { print -P "\n%B▶ $1%b"; }
die() {
 print -P "\n%F{red}✗ $1%f"
 if ditto -c -k "$log_dir" "$log_dir.zip" > /dev/null 2>&1; then print "安装诊断包：$PWD/$log_dir.zip"; fi
 print "详细日志：$PWD/$log_dir"
 print "按回车键关闭窗口。"; read -r _; exit 1
}

print -P "%BPadInk · 开发更新%b"
print "首次编译可能需要数分钟。"
print "本次版本身份：$app_name；开发版与正式版分别配对。"
if [[ "$ipad_installer" == altstore ]]; then
 print "本次更新 Mac 并生成 iPad IPA；iPad 安装与续签交给官方 AltStore。保留已有 App 和原 Apple ID。"
else
 print "本次通过 Xcode 更新 Mac 和 iPad。不要删除 iPad 上的旧 App，也不要更换 Apple ID 团队。"
 print "请保持 iPad 用数据线连接且已解锁。"
fi
step "1/6 检查 Xcode 与本机签名"
xcodebuild -version > "$log_dir/xcode.txt" 2>&1 || die "没有找到可用的 Xcode。请从 App Store 安装 Xcode 并打开一次；已安装时，在 Xcode › 设置 › 位置中把命令行工具选为 Xcode。"
head -1 "$log_dir/xcode.txt"
xcodebuild -checkFirstLaunchStatus > "$log_dir/xcode-setup.txt" 2>&1 || die "Xcode 的首次准备尚未完成。请打开 Xcode，完成许可与组件安装后重试。"
./engineering/scripts/configure-local-signing.sh --check > "$log_dir/signing.txt" 2>&1 || die "$(cat "$log_dir/signing.txt")"
cat "$log_dir/signing.txt"

step "2/6 检查 iPad"
if [[ "$ipad_installer" == xcode ]]; then
udid=$(python3 engineering/scripts/lib/device_check.py 2> "$log_dir/device.txt") || die "$(cat "$log_dir/device.txt")"
cat "$log_dir/device.txt"
else
 print "生成 IPA 不需要连接 iPad；导入与续签时须让 AltStore 能连接到 AltServer。"
fi

step "3/6 准备同一版本的两端工程"
commit=$(python3 engineering/scripts/build-identity.py) || die "无法生成源码构建标识。"
python3 engineering/scripts/build-identity.py --json > "$log_dir/source-manifest.json" || die "无法保存源码追溯信息。"
python3 engineering/scripts/generate-project.py > "$log_dir/generate.txt" 2>&1 || die "无法生成 Xcode 工程（见 generate.txt）。"
source_revision=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["head"])' "$log_dir/source-manifest.json") || die "无法读取源码提交标识。"
source_digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceSHA256"])' "$log_dir/source-manifest.json") || die "无法读取源码摘要。"
print "本次构建：$commit"

step "4/6 编译 Mac 端"
xcodebuild -project PadInk.xcodeproj -scheme PadInkMac -configuration Release -destination 'platform=macOS' \
 -derivedDataPath build/update/DerivedData -allowProvisioningUpdates PADINK_SOURCE_COMMIT="$commit" PADINK_SOURCE_REVISION="$source_revision" PADINK_SOURCE_SHA256="$source_digest" PADINK_BUILD_VARIANT="$variant" PADINK_RELEASE_CHANNEL="$channel" PADINK_DISTRIBUTION="$distribution" build > "$log_dir/mac-build.txt" 2>&1 \
 || { grep -qi 'No Account for Team\|Signing for\|No signing certificate\|Unable to log in' "$log_dir/mac-build.txt" && die "Mac 端签名失败：请打开 Xcode › 设置 › 账户，确认首次设置使用的 Apple ID 仍已登录，并处理账户旁的提示。" || die "Mac 端编译失败（见 mac-build.txt）。"; }
mac_app="build/update/DerivedData/Build/Products/Release/$app_name.app"

if [[ "$ipad_installer" == altstore ]]; then
 step "5/6 生成供 AltStore 安装的 iPad IPA"
 python3 engineering/scripts/build-altstore-ipa.py --variant "$variant" --out "$log_dir/altstore" > "$log_dir/ipad-package.txt" 2>&1 \
  || die "iPad IPA 构建失败（见 ipad-package.txt 与 altstore/ipad-build.log）。"
 ipa_name=PadInk-AltStore.ipa; [[ "$variant" != development ]] || ipa_name=PadInk-Dev-AltStore.ipa
 ipad_ipa="$PWD/$log_dir/altstore/$ipa_name"
else
 step "5/6 编译并覆盖安装 iPad 端"
xcodebuild -project PadInk.xcodeproj -scheme PadInkPad -configuration Release -destination "id=$udid" \
 -derivedDataPath build/update/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration PADINK_SOURCE_COMMIT="$commit" PADINK_SOURCE_REVISION="$source_revision" PADINK_SOURCE_SHA256="$source_digest" PADINK_BUILD_VARIANT="$variant" PADINK_RELEASE_CHANNEL=development PADINK_DISTRIBUTION=developer build > "$log_dir/ipad-build.txt" 2>&1 \
 || { grep -qi 'is not supported by this version of Xcode\|Unsupported OS\|newer version of Xcode' "$log_dir/ipad-build.txt" && die "Xcode 版本过旧，不支持当前 iPad 系统。请先在 App Store 更新 Xcode。" \
      || grep -qi 'App ID limit\|maximum number of App IDs\|maximum number of registered app IDs' "$log_dir/ipad-build.txt" && die "免费 Apple ID 的 App ID 注册额度已满。删除已装 App 不会立即释放此额度；请等 Apple 的额度周期重置后重试，保留 PadInk。" \
      || grep -qi 'maximum number of apps\|maximum number of free apps\|maximum number of free application' "$log_dir/ipad-build.txt" && die "这台 iPad 可安装的免费签名测试 App 数量已满。请删除一个不用的测试 App，再重试（不要删除 PadInk）。" \
      || grep -qi 'No Account for Team\|No signing certificate\|Unable to log in\|authentication' "$log_dir/ipad-build.txt" && die "iPad 签名失败：请在 Xcode › 设置 › 账户中确认原 Apple ID 已登录，处理账户旁的提示后重试。" \
      || die "iPad 端编译或签名失败（见 ipad-build.txt）。"; }
ipad_app="build/update/DerivedData/Build/Products/Release-iphoneos/$app_name.app"
xcrun devicectl device install app --device "$udid" "$ipad_app" > "$log_dir/ipad-install.txt" 2>&1 \
 || { grep -qi 'locked' "$log_dir/ipad-install.txt" && die "iPad 没有解锁。请解锁并保持亮屏后重试。" \
      || grep -qi 'maximum number of apps\|maximum number of free apps\|maximum number of free application' "$log_dir/ipad-install.txt" && die "这台 iPad 的免费签名测试 App 数量已满。请删除一个不用的测试 App（保留 PadInk）后重试。" \
      || grep -qi 'developer mode' "$log_dir/ipad-install.txt" && die "请在 iPad 设置 › 隐私与安全性 › 开发者模式中启用，重启并确认后重试。" \
      || grep -qi 'untrusted\|not trusted' "$log_dir/ipad-install.txt" && die "iPad 尚未信任开发者。请在 设置 › 通用 › VPN 与设备管理 中信任自己的 Apple ID 后重试。" \
      || die "安装到 iPad 失败（见 ipad-install.txt）。"; }
python3 - "$ipad_app/embedded.mobileprovision" > "$log_dir/signing-expiry.txt" 2>&1 <<'PY'
import datetime, plistlib, subprocess, sys
result = subprocess.run(["security", "cms", "-D", "-i", sys.argv[1]], capture_output=True)
if result.returncode == 0:
    expiry = plistlib.loads(result.stdout).get("ExpirationDate")
    if expiry:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc).astimezone()
        print("本次 iPad 签名有效至：" + expiry.strftime("%Y-%m-%d %H:%M %Z"))
PY
cat "$log_dir/signing-expiry.txt"
fi

step "6/6 安装并打开 Mac 端"
destination_dir=${PADINK_INSTALL_DIRECTORY:-/Applications}
[[ -d "$destination_dir" && -w "$destination_dir" ]] || die "无法写入 $destination_dir；请先核对应用程序文件夹的安装权限，保留已有 App。"
installed_app="$destination_dir/$app_name.app"
receipt="$PWD/$log_dir/mac-install.json"
python3 engineering/scripts/lib/mac_install.py install --source "$mac_app" --destination-dir "$destination_dir" --receipt "$receipt" > "$log_dir/mac-install.txt" 2>&1 \
 || die "$(cat "$log_dir/mac-install.txt")"
cat "$log_dir/mac-install.txt"
if [[ "$ipad_installer" == xcode ]]; then
 ipad_bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$ipad_app/Info.plist")
if xcrun devicectl device process launch --device "$udid" "$ipad_bundle" > "$log_dir/ipad-launch.txt" 2>&1; then
 print "iPad 端已打开。"
else
 print "iPad 端已安装，请在 iPad 主屏幕打开“$app_name”。若提示开发者不受信任，到 设置 › 通用 › VPN 与设备管理 中信任自己的 Apple ID。"
fi
print -P "\n%F{green}✓ 两端安装完成 · 构建 $commit%f"
print "Mac 应用：$installed_app"
print "首次使用：打开 Mac 菜单栏 $app_name，授权屏幕录制和辅助功能；iPad 保持 $app_name 在前台，首次在两端各点“允许配对”。"
print "已配对设备稍后会自动连接。看到 iPad 上的 Mac 画面后，在目标应用里选择笔或标注工具再书写。"
print "每周续期继续使用这份文件夹和原 Apple ID。过期也不要删除 iPad App，直接覆盖更新。"
else
 print -P "\n%F{green}✓ Mac 更新完成，iPad IPA 已生成 · 构建 $commit%f"
 print "Mac 应用：$installed_app"
 print "iPad IPA：$ipad_ipa"
 print "将 IPA 传到 iPad，在 AltStore › My Apps › + 导入；完成后再核对双端版本与配对。"
 print "续签：启用 AltStore › Settings › Background Refresh，并保持 Mac 上 AltServer 运行。"
 print "手动核对：AltStore › My Apps › Refresh All；自动续签不会替你导入新代码。"
 print "从 Xcode 改为 AltStore 是一次身份切换，请按开发者指南迁移，不能当作同身份覆盖更新。"
 [[ ${PADINK_REVEAL_IPA:-1} != 1 ]] || open -R "$ipad_ipa"
fi
print "请检查 $app_name 的设置、已配对设备与实际连接；覆盖更新时确认它们是否保持；确认前会保留旧名应用和回滚备份。"
print "确认已保持时输入 yes 并按回车；直接按回车保留旧版本。"
read -r state_confirm || state_confirm=""
if [[ "$state_confirm" == yes ]]; then
 python3 engineering/scripts/lib/mac_install.py finalize --receipt "$receipt" --confirm-state-preserved > "$log_dir/mac-finalize.txt" 2>&1 \
  || die "$(cat "$log_dir/mac-finalize.txt")"
 cat "$log_dir/mac-finalize.txt"
else
 print "旧版本及回滚备份已保留。稍后验证通过可运行："
 print "python3 engineering/scripts/lib/mac_install.py finalize --receipt \"$receipt\" --confirm-state-preserved"
 print "需要回滚时运行：python3 engineering/scripts/lib/mac_install.py rollback --receipt \"$receipt\""
fi
print "操作说明：docs/开发者指南.md；安装日志：$PWD/$log_dir"
print "按回车键关闭窗口。"; read -r _ || true
