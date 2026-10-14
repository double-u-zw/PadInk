# PadInk

[![CI](https://github.com/double-u-zw/PadInk/actions/workflows/check.yml/badge.svg?branch=main)](https://github.com/double-u-zw/PadInk/actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**把 iPad 变成 Mac 的手写与触控屏。**

PadInk 将 Mac 主屏画面显示在 iPad 上。用 Apple Pencil 在 Mac 应用中书写、批注，用手指点击、拖动、滚动和缩放；文稿由 Mac 上的目标应用保存。首次使用建议通过 USB 数据线连接。

## 版本与下载

| 版本 | 使用方式 | 当前状态 |
|---|---|---|
| **0.3.0 Beta 3 · build 11** | Mac 测试包 + iPad AltStore | 已公开，可从下方下载；Mac 包未公证 |
| **0.3.0 · build 12** | Mac 公证包 + iPad TestFlight | 维护者已安装并初步试用；尚无公开安装入口，未提交 App Store 审核 |
| **main 源码** | 自行构建 | 包含 build 12 产品源码、回归测试、工程工具与当前文档 |

**Mac 仅支持 Apple Silicon（M 系列 / arm64），不提供 Intel 版本。**

[下载 Beta 3 完整测试包（M 系列 Mac + iPad）](https://github.com/double-u-zw/PadInk/releases/download/v0.3.0-beta.3/PadInk-0.3.0-b11-Beta-arm64.zip) · [发布记录](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-beta.3)

ZIP 包含 Mac DMG、`PadInk-AltStore.ipa`、安装说明、使用教程和校验文件。历史发布页中的 Intel 资产保留原记录，已不在维护与支持范围。

**已在使用 TestFlight build 12：** iPad 通过 TestFlight 更新，Mac 使用维护者提供的配套 build 12 公证包；测试有效期以 TestFlight 显示为准。请按安装渠道更新，更新前核对两端版本和配套构建。

## 使用条件

- M 系列 Mac，macOS 14 或更新版本。
- iPad，iPadOS 17 或更新版本；手写需要兼容的 Apple Pencil。
- 能传输数据的 USB 线；iPad 保持解锁，PadInk 保持前台。
- Mac 允许 PadInk 使用屏幕录制和辅助功能；两端首次连接时确认设备配对。

系统下限是工程要求，最低系统和更多设备的真机验证仍待完成。目标应用的书写、保存和缩放能力见[支持范围](docs/SUPPORT_MATRIX.md)。

## 开始使用

1. **安装两端。** 公开 Beta 3：解压完整测试包，把 Mac DMG 中的 PadInk 拖到“应用程序”；按[安装说明](docs/AltStore安装说明.txt)安装官方 AltServer 和 AltStore Classic，再在 iPad 的 AltStore 导入 `PadInk-AltStore.ipa`。需要自己的 Apple ID，使用者无需 Xcode 或付费开发者会员。首次打开未公证 Mac 测试包时，按安装说明处理系统提示。
2. **连接设备。** 打开两端 PadInk，用 USB 线连接 Mac 和 iPad，按系统提示信任设备，并在两端确认配对。VPN 可以保持开启。
3. **开始书写。** 在 Mac 打开文稿，让目标应用处于前台并选择笔或批注工具，再用 iPad 上的 Pencil 书写。手指可操作界面，双指可滚动；捏合缩放取决于目标应用的支持。
4. **保存文稿。** 在 Mac 的目标应用中保存，关闭并重新打开，确认结果。先用测试文稿熟悉操作。

PowerPoint、GoodNotes、Preview 等应用的具体操作见[使用教程](docs/使用教程.md)。配套 Ecru 需要指定适配构建，由维护者单独提供。

## 更新与排障

**AltStore Beta：** 免费签名通常约 7 天有效。保持 Mac 的 AltServer 可达，在 AltStore 使用 **Refresh All** 续签；安装新版本时需重新导入新版 IPA。后台刷新由系统调度，不能保证每次按时成功。

**TestFlight：** 在 TestFlight 安装新版 iPad App，并同步更新配套 Mac App。更新前保存文稿，保留现有设置与配对；切换账号、签名团队或渠道时，按[安装与升级指南](docs/使用者安装指南.md)核对迁移方式。

| 现象 | 先检查 |
|---|---|
| 连不上 | 数据线是否支持传输、iPad 是否解锁、两端 App 是否打开、版本是否匹配 |
| 有连接但没画面 | Mac 的屏幕录制权限；按系统要求退出并重新打开 PadInk |
| 有画面但不能写 | Mac 的辅助功能权限、目标文稿是否在前台、是否已选择笔工具 |
| 滚动或缩放无效 | 手指输入开关、目标应用能力、文稿焦点；先退出菜单或弹窗 |

首次推荐 USB；Wi-Fi 需要同一局域网、本地网络权限和配对，受限网络的兼容性仍待验证。完整说明见[安装、更新与排障](docs/使用者安装指南.md)。

## 源码开发

```sh
git clone https://github.com/double-u-zw/PadInk.git
cd PadInk
./engineering/scripts/build-and-test.sh
```

本地已验证工具链为 Xcode 27；GitHub CI 使用 Xcode 26.3，运行回归测试与 Mac arm64、iPad 无签名 Release 构建。自动检查通过代表对应源码检查通过，真机体验与发行渠道另行验收。

`main` 提供最新源码。历史 Beta 3 tag 的自动 Source code 附件保留当时的公开基线。自行构建和签名见[开发者指南](docs/开发者指南.md)；源码开发身份与正式安装身份的设置、配对和服务彼此独立。

- [架构](docs/ARCHITECTURE.md) · [协议](docs/PROTOCOL.md) · [工程工具](engineering/README.md)
- [发行流程与当前验收状态](docs/RELEASE.md) · [真人验收清单](docs/试用验收清单.txt)

## 反馈与隐私

通过 [GitHub Issues](https://github.com/double-u-zw/PadInk/issues)反馈设备与系统、两端版本、目标应用、连接方式和复现步骤。完整长时间文稿、外部设备首装、最低系统及 Wi-Fi 恢复仍待更多验证。

PadInk 没有云端账户、广告或自动上传诊断。诊断是否分享由你决定；公开反馈请移除个人文稿、账号凭据和配对密钥。详见[隐私政策](docs/PRIVACY.md)。

源码采用 [MIT License](LICENSE)。
