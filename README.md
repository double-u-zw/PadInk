# PadInk

**让 iPad 成为 Mac 的手写与触控屏。**

PadInk 将 Mac 画面显示在 iPad 上，让你使用 Apple Pencil 在 Mac 应用中书写、批注，并通过手指完成点击、拖动、滚动和缩放。适用于文档阅读、演示批注与日常手写，文稿由 Mac 上的目标应用保存。

## 主要功能

- **画面同步**：在 iPad 上查看 Mac 主屏画面，配合 USB 连接进行操作。
- **Pencil 书写**：在支持笔或批注工具的 Mac 应用中直接书写、标记和擦除。
- **触控操作**：支持点击、拖动与双指滚动；缩放能力取决于目标应用。

PowerPoint、GoodNotes、Preview 等应用的操作方式与适用范围，详见[使用教程](docs/使用教程.md)和[支持说明](docs/SUPPORT_MATRIX.md)。

## 下载与安装

当前版本：**0.3.0 测试版**。Mac 版本已通过 Apple 公证；iPad 版本目前通过 TestFlight 向受邀使用者提供，尚未在 App Store 上架。

[下载 Mac 版（M 系列）](https://github.com/double-u-zw/PadInk/releases/download/v0.3.0-rc.1-build12/PadInk-0.3.0-b12-mac-arm64-DeveloperID-notarized.zip) · [版本说明](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-rc.1-build12)

1. 下载并解压 Mac 安装包，将 **PadInk.app** 放入“应用程序”。
2. 在 iPad 的 TestFlight 中安装配套版本。当前 Mac 版对应 **TestFlight 0.3.0（12）**，安装需要有效测试邀请。
3. 打开两端 PadInk，按提示允许 Mac 的屏幕录制和辅助功能权限。

更新时，请同步更新两端应用，并先保存正在编辑的文稿。详细步骤见[安装与更新指南](docs/使用者安装指南.md)。

## 使用条件

- **Mac**：Apple Silicon（M 系列），macOS 14 或更新版本。
- **iPad**：iPadOS 17 或更新版本；手写需要兼容的 Apple Pencil。
- **连接**：支持数据传输的 USB 线；iPad 保持解锁，PadInk 保持前台运行。

PadInk 当前仅支持 M 系列 Mac，不支持 Intel Mac。首次使用建议通过 USB 连接；无线连接的配置见[使用教程](docs/使用教程.md)。

## 开始使用

1. **连接设备**：打开两端 PadInk，连接 USB 数据线，按提示信任设备并确认配对。
2. **打开文稿**：在 Mac 上打开目标应用和文稿，选择笔、橡皮或批注工具。
3. **书写与操作**：使用 Apple Pencil 书写，用手指选择工具、滚动页面或调整视图。
4. **保存文稿**：在 Mac 的目标应用中保存。初次使用可先用一份测试文稿熟悉操作。

如遇连接、画面或输入问题，请参阅[安装与排障指南](docs/使用者安装指南.md)。

## 支持与隐私

如需帮助或反馈问题，请通过 [GitHub Issues](https://github.com/double-u-zw/PadInk/issues)提供应用版本、设备与系统版本、连接方式和问题描述。

PadInk 的画面与输入在配对设备之间传输。应用无需云端账户，不含广告，诊断信息由使用者自主选择是否分享。提交公开反馈时，请勿附带个人文稿或账号信息。详见[隐私政策](docs/PRIVACY.md)。

本项目采用 [MIT 许可证](LICENSE)。
