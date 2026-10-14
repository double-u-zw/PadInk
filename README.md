# PadInk

把 iPad + Apple Pencil 变成 Mac 的触控与手写终端：在 iPad 看 Mac 画面，用 Pencil 书写，用手指点击、拖动、双指滚动和缩放。文稿由 Mac 上的目标应用保存。

当前公开试用版：**[0.3.0 Beta 3 / build 11](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-beta.3)**。优先用 USB 体验；本次修复了 iPad 视频反馈中正常关键帧替换被误判为拥塞、导致不必要降帧率的问题。

## 下载

在 Mac 的“关于本机”查看芯片，只下载对应的一份完整 ZIP：

| Mac 芯片 | 完整安装包 |
|---|---|
| Apple M 系列 | [下载 arm64](https://github.com/double-u-zw/PadInk/releases/download/v0.3.0-beta.3/PadInk-0.3.0-b11-Beta-arm64.zip) |
| Intel | [下载 x86_64](https://github.com/double-u-zw/PadInk/releases/download/v0.3.0-beta.3/PadInk-0.3.0-b11-Beta-x86_64.zip) |

每份 ZIP 包含 Mac DMG、共用的 `PadInk-AltStore.ipa`、安装说明、使用教程和校验文件。需要 macOS 14+、iPadOS 17+、USB 数据线；手写另需与 iPad 兼容的 Apple Pencil。Intel 和最低系统尚未完成真机验收。

## 首次安装与使用

1. 解压 ZIP，打开 Mac DMG，将 `PadInk.app` 拖到“应用程序”。**Mac 测试包尚未公证**，首次打开按[安装说明](docs/AltStore安装说明.txt)处理系统提示，允许屏幕录制和辅助功能；不关闭系统安全检查。
2. 从[官方链接](https://cdn.altstore.io/file/altstore/altserver/1_8_1.zip)下载 AltServer，按[官方指南](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)在自己的 iPad 安装 AltStore Classic。需要自己的 Apple ID、设备信任和开发者模式，**无需 Xcode 或付费开发者会员**；账号密码只在官方窗口输入。
3. 在 iPad 从 [Beta 3 发布页](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-beta.3)下载完整 ZIP，在“文件”中解压；打开 AltStore → My Apps →“+”，选择 `PadInk-AltStore.ipa`。也可用自己的 iCloud 云盘传文件。
4. 打开两端 PadInk，解锁 iPad，用 USB 数据线连接 Mac，只允许正在使用的两台设备配对。**VPN 可以保持开启。**
5. 在 Mac 打开测试文稿，选择目标应用的笔工具，再用 iPad 写字、点击和双指操作；保存、关闭、重开文稿确认结果。更多操作见[使用教程](docs/使用教程.md)。

PadInk 不包含第三方目标应用，也不提供独立 iPad 笔记本。Ecru 需指定配套构建；其他应用的书写与缩放能力见[支持范围](docs/SUPPORT_MATRIX.md)。

## 续签与更新

iPad 免费签名约 **7 天**有效。续签时保持自己的 Mac 开机、AltServer 可达，在 AltStore 用 **Refresh All**；后台刷新不能保证每次按时完成。

收到新版本时，先保存文稿、退出 Mac PadInk，覆盖同渠道 Mac App，并在 AltStore 用“+”导入**新版 IPA**。Refresh All 只续签已有代码，不会下载新版。保持原 Apple ID，不先卸载、Deactivate 或删除配对；不同账号、团队或渠道的设置与配对不能保证迁移，先保留旧 App 并联系维护者。

## 试用反馈

先完成 USB 首次安装与真实文稿，再补长时间使用和恢复测试。按[真人验收清单](docs/试用验收清单.txt)记录，通过 [GitHub Issues](https://github.com/double-u-zw/PadInk/issues)反馈设备、系统、两端版本、目标应用、发生时间和操作步骤。

诊断由你选择是否分享；Issues 是公开内容，不附个人文稿、账号凭据、证书或私钥。见[隐私政策](docs/PRIVACY.md)和[安装、升级与排障](docs/使用者安装指南.md)。第二套设备、完整长时间文稿、Intel、最低系统、Wi-Fi 恢复、后台续签及实际过期恢复仍待反馈；历史构建的记录不能代替本次公开包验收。

## 源码与后续发行

当前 `main` 提供 build 12 的最新源码、回归测试、工程工具和文档，采用 [MIT](LICENSE)。历史 Beta 3 tag 的 Source code 附件仍是当时的公开基线；获取最新源码请克隆 `main`。本机签名配置、证书、凭据和设备数据不公开。普通安装继续使用上面的 Beta ZIP；源码构建见[开发者指南](docs/开发者指南.md)，实际安装包身份见包内 `VERSIONS.json` 及两端关于页面。

正式发行目标是 iPad App Store + Mac Developer ID 签名与 Apple 公证包，目前尚无这些正式公开下载入口。当前 GitHub Beta 仍使用 AltStore。0.3.0 / build 12 已完成 M 系列 Mac 公证与 TestFlight 上传处理，维护者已确认使用这套组合初步试用未发现问题；完整逐项验收和外部设备首装尚未完成，未提交 App Store 审核或公开发布 build 12 安装包。详情见[发布流程](docs/RELEASE.md)。开发身份与正式身份的设置、配对和服务彼此独立。
