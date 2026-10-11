# PadInk

把 iPad + Apple Pencil 变成 Mac 的触控与手写终端：在 iPad 看 Mac 主屏，用 Pencil 书写、手指点按、双指滚动与缩放。文稿由 Mac 目标应用保存。

当前版本为 **0.3.0 Beta 1（build 5）公开测试版**，首次推荐 USB。这是安装包与使用文档的发布仓库；GitHub 自动生成的 Source code 附件只包含发布文档，完整产品源码目前由维护者私下保留。

## 下载与安装

1. 从 [Beta 1 发布页](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-beta.1)下载 `PadInk-0.3.0-b5-Beta.zip`，解压后先读“安装说明.txt”。发布页提供 SHA256SUMS 校验文件。
2. Mac 打开包内 `PadInk-Mac-Test.dmg`，将 PadInk 放进“应用程序”，按说明授权屏幕录制和辅助功能。当前 Mac 包未公证，首次打开需按系统流程确认。
3. 从[官方固定链接](https://cdn.altstore.io/file/altstore/altserver/1_8_1.zip)下载 AltServer 1.8.1，按[安装说明](docs/AltStore安装说明.txt)在 iPad 安装 AltStore Classic，再导入包内 `PadInk-AltStore.ipa`。
4. 两端打开，用 USB 连接并确认自己的设备；在 Mac 文稿中选笔后开始书写。保存、关闭、重开文稿确认结果。

使用者无需 Xcode 或付费开发者会员；首次需要自己的 Apple ID、设备信任和开发者模式。免费 iPad 签名约 7 天有效，在 AltStore 续签；Refresh All 只续签当前版本，不自动更新 PadInk 代码。

## 当前验证范围

完整自动检查共 527 项，6 项跳过、零失败；双端 Release 构建、文件校验、版本和源码身份核对通过。此前在 Apple Silicon Mac / macOS 27.0.1、iPad Air 5 / iPadOS 27.0.1 有 USB 使用、安装与续签记录，Ecru 有 USB 操作反馈；这些记录不能代替本构建完整真人验收。

本 build 的独立安装、真实文稿、长时间使用、Wi-Fi、续签和覆盖升级仍待逐项确认。工程最低版本为 macOS 14 / iPadOS 17，Intel、最低系统及更多设备尚未真机验收。Mac 尚无 Developer ID 公证，iPad 当前通过 AltStore 安装，尚无 TestFlight 或 App Store 入口。配套 Ecru 需要指定适配构建，本包不包含 Ecru。

## 文档与反馈

- [安装、升级与恢复](docs/使用者安装指南.md)
- [支持范围](docs/SUPPORT_MATRIX.md)
- [真人验收清单与反馈模板](docs/试用验收清单.txt)
- [隐私说明](docs/PRIVACY.md)
- [问题反馈](https://github.com/double-u-zw/PadInk/issues)

请附设备/系统、两端 build、目标应用、USB/Wi-Fi 和复现步骤。Issues 为公开反馈，分享诊断前自行查看；不要提交个人文稿、密码、验证码、证书或钥匙串。
