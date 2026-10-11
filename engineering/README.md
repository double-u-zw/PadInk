# PadInk 工程工具

PadInk Dev 与 PadInk 分别是开发版和正式版产品身份；芯片包分别构建 arm64 / x86_64，见发布流程。

所有开发、安装、打包、诊断与实验入口集中在本目录。下面命令从仓库根目录运行；源码安装的 `.command` 也可在 Finder 中双击，它们会自行定位工程根目录。

| 目录 | 用途 |
|---|---|
| `scripts/` | 构建、工程生成、身份校验、源码/安装包/RC 打包、签名配置与工具自测 |
| `scripts/lib/` | 设备检查、本机签名配置与可回滚 Mac 安装的内部辅助模块 |
| `commands/` | 源码首次设置、双端开发安装/续期、按提交打包源码的快捷入口 |
| `tools/Replay/`、`tools/ReplayKit/` | SwiftPM 的 `padink-replay` 与文稿持久化比较；不进入产品 App |
| `tools/WebProbe/`、`tools/WebProbeTLS/` | 独立网络诊断实验，不属于产品或发布验收，未接入 App 构建 |

常用入口：

```sh
./engineering/scripts/build-and-test.sh
PADINK_BUILD_CHANNEL=rc ./engineering/scripts/build-and-test.sh
python3 engineering/scripts/build-identity.py --json
python3 engineering/scripts/rc-release.py prepare --preview --out build/rc/preview
python3 engineering/scripts/rc-release.py check build/rc/preview
./engineering/commands/打包源码.sh
```

`scripts/test-*.py` 和 `selftest_build_identity.py` 是工程工具的隔离自测；统一检查同时运行它们。产品回归仍在根目录 `Tests/`，固定输入样本在 `Fixtures/`；版本/身份配置在 `Config/`，App 发行入口与资源在 `Hosts/`。这些属于常规工程结构，无需随辅助工具搬迁。

工程生成应修改 `scripts/generate-project.py` 后运行；生成的 `PadInk.xcodeproj` 留在根目录供 Xcode 打开。构建、截图、诊断、安装回滚材料与候选输出统一在 ignored 的 `build/`，SwiftPM 缓存 `.build/` / `.swiftpm/` 不进入源码提交。签名配置仍留在 ignored 的 `Config/*.local.xcconfig`，不要移动或提交。

本地检查和候选准备不安装或发布。`commands/更新 PadInk.command` 默认更新 Mac 开发版并准备 AltStore IPA，iPad 导入及后台续签交给 AltStore；显式 `PADINK_IPAD_INSTALLER=xcode` 才覆盖安装双端；`rc-release.py mac` 会向 Apple 提交公证；回放会接管指针。运行这些操作前按任务授权及实际环境选择入口。

完整操作见[开发者指南](../docs/开发者指南.md)，正式签名与真人待办见[发布流程](../docs/RELEASE.md)。
