# PadInk

把 iPad + Apple Pencil 变成 Mac 的触控与手写终端。Mac 画面显示在 iPad 上，书写、点击、双指滚动和缩放作用于 Mac 当前应用；文稿由 PowerPoint、GoodNotes 等目标应用保存。

正式版名称为 **PadInk**，开发版为 **PadInk Dev**。版本通过 Git commit / tag、App Version / Build 与 RC / Release 管理。两版分别安装到 `/Applications/PadInk.app` 与 `/Applications/PadInk Dev.app`；版本、渠道和完整源码身份可在关于与诊断中查看。

免费安装与续签采用**官方 AltServer + AltStore Classic**：维护者构建 IPA，用户通过 AltStore 安装并由其管理续签，不需要 Xcode 或付费会员。首次设置需要 Apple ID、设备信任和开发者模式；免费签名仍约 7 天有效。已通过 AltServer 1.8.1 / AltStore Classic 2.3 在 iPadOS 27.0.1 安装独立版 PadInk，并完成原位续签：签名到期时间延后，身份、测试文件、设置和配对保留，USB 画面与 Pencil 正常。后台自动刷新、过期恢复和纯无 Xcode Mac 环境尚待实测。PadInk 不自行处理 Apple ID 认证或签名。

Mac Developer ID 公证包、iPad TestFlight / App Store 的发行工具保留，但尚未发布可下载的公证包或 TestFlight 邀请。Xcode 签名与更新脚本继续用于现有开发安装。

本轮公开测试版本为 **0.3.0 Beta 2（build 9）**，使用 PadInk 产品身份，双端渠道为 `rc`、安装方式为 `altstore`。下载及实际发布状态以 [Beta 2 发布页](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-beta.2)为准。build 9 基于已验证安装与手动续签的 build 8 开发源码，补齐双架构下载和使用文档；本次公开包的完整真人验收仍未完成，历史使用记录不能代替本包验收。

下载按 Mac 芯片选择：**M 系列用 [arm64 完整安装包](https://github.com/double-u-zw/PadInk/releases/download/v0.3.0-beta.2/PadInk-0.3.0-b9-Beta-arm64.zip)，Intel 用 [x86_64 完整安装包](https://github.com/double-u-zw/PadInk/releases/download/v0.3.0-beta.2/PadInk-0.3.0-b9-Beta-x86_64.zip)**。每份 ZIP 都包含对应的 Mac DMG、相同的 iPad IPA、安装说明、使用教程与校验文件。先按[安装步骤](docs/AltStore安装说明.txt)完成安装，再按[使用教程](docs/使用教程.md)完成首份文稿。Mac 包未公证，iPad 通过 AltStore 安装；使用者无需 Xcode 或付费会员。

尚未完成的验证：本次公开包的独立安装、完整文稿、30–60 分钟使用、Wi-Fi 切换/恢复、覆盖升级；Intel 实机、最低系统、第二套设备、自动后台续签周期及实际过期恢复。此前开发版安装与手动续签记录仅证明对应版本和现有设备，详见[支持范围](docs/SUPPORT_MATRIX.md)。

官方 AltServer 从[固定链接](https://cdn.altstore.io/file/altstore/altserver/1_8_1.zip)下载。免费 iPad 签名约 7 天有效；后台刷新需要 AltServer 可达，定期在 AltStore 查看有效期并用 Refresh All 手动检查。新代码仍需导入新 IPA。

开发版与正式版使用独立身份、设置和配对；Mac 与 iPad 必须安装同一版。日常源码构建和更新命令默认 **PadInk Dev**，开发版 iPad 也用官方 AltStore + AltServer 管理安装与后台续签；更新命令安装 Mac 并准备 IPA，iPad 需在 AltStore 导入；给使用者的安装候选默认 **PadInk**。正式版产品身份可以用于 Beta/RC，稳定性仍以发布状态和真人验收为准。

Mac 下载按芯片区分：**Apple Silicon / M 系列选 arm64，Intel 选 x86_64**；两个包使用同一版身份，版本与源码一致。Beta 2 分别提供两个单架构包；Intel 包构建已核对，Intel 真人验收仍待完成。Beta 1 / build 5 的旧通用资产保留。

| 想做什么 | 文档 |
|---|---|
| 从第一份文稿到日常使用 | [使用教程](docs/使用教程.md) |
| 安装、升级、首次使用与恢复 | [使用者安装指南](docs/使用者安装指南.md) |
| 查看应用、设备与未验证边界 | [支持矩阵](docs/SUPPORT_MATRIX.md) |
| 从源码安装、构建、测试、回放与截图 | [开发者指南](docs/开发者指南.md) |
| 理解模块、输入安全与恢复 | [架构说明](docs/ARCHITECTURE.md) |
| 修改帧、消息与配对协议 | [协议说明](docs/PROTOCOL.md) |
| 准备和校验候选、签名与分发 | [Release 流程](docs/RELEASE.md) |
| 了解诊断与隐私 | [隐私说明](docs/PRIVACY.md) |

`Apps/` 是双端产品逻辑，`Sources/` 是共享核心与传输，`Hosts/` 是 App 入口与发行资源，`Tests/` 和 `Fixtures/` 是回归，[工程工具](engineering/README.md)统一在 `engineering/`，包含构建脚本、安装命令、回放和实验工具；`Config/` 是版本与签名配置。`PadInk.xcodeproj` 由脚本生成，`build/` 仅承载 ignored 的当前本地输出。

```sh
git clone https://github.com/double-u-zw/PadInk.git
cd PadInk
./engineering/scripts/build-and-test.sh
python3 engineering/scripts/rc-release.py prepare --preview
```

预览允许未提交源码；正式候选绑定干净提交。安装包、签名、公证与真人验收各自核对。检查和预览不会发布或上传。本机恢复备份、诊断与签名配置不进入公开仓库。

源码采用 [MIT](LICENSE) 许可证。克隆仓库后按[开发者指南](docs/开发者指南.md)运行测试与构建；签名配置由每位开发者本机生成，不提供维护者凭据。
