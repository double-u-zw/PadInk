# PadInk 工程工具

development 与 release 是分别隔离的开发和正式身份，界面名称同为 PadInk；本轮正式 Mac 候选只构建与公证 arm64（M 系列），历史双架构包保留原记录，见发布流程。

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
python3 engineering/scripts/check-store-bundle.py build/app-store/check/dd/Build/Products/Release-iphoneos/PadInk.app
python3 engineering/scripts/rc-release.py prepare --preview --out build/rc/preview
python3 engineering/scripts/rc-release.py check build/rc/preview
./engineering/commands/打包源码.sh
```

`scripts/test-*.py` 和 `selftest_build_identity.py` 是工程工具的隔离自测；统一检查同时运行它们。产品回归仍在根目录 `Tests/`，固定输入样本在 `Fixtures/`；版本/身份配置在 `Config/`，App 发行入口与资源在 `Hosts/`。这些属于常规工程结构，无需随辅助工具搬迁。

工程生成应修改 `scripts/generate-project.py` 后运行；生成的 `PadInk.xcodeproj` 留在根目录供 Xcode 打开。构建、截图、诊断、安装回滚材料与候选输出统一在 ignored 的 `build/`，SwiftPM 缓存 `.build/` / `.swiftpm/` 不进入源码提交。签名配置仍留在 ignored 的 `Config/*.local.xcconfig`，不要移动或提交。

本地检查和候选准备不安装或发布。`commands/更新 PadInk.command` 默认更新 Mac 开发版并准备 AltStore IPA，iPad 导入及后台续签交给 AltStore；显式 `PADINK_IPAD_INSTALLER=xcode` 才覆盖安装双端；`rc-release.py mac` 会向 Apple 提交公证；回放会接管指针。运行这些操作前按任务授权及实际环境选择入口。

完整操作见[开发者指南](../docs/开发者指南.md)，正式签名与真人待办见[发布流程](../docs/RELEASE.md)。

商店字段与素材：先用 `rc-release.py prepare --preview` 冻结当前未提交工程，再用 `python3 engineering/scripts/store-materials.py --release <冻结目录> --out build/app-store/materials-build12` 绑定当前 build 12 并导出资料。`--release <干净候选> --require-ready` 拒绝历史、未提交与待确认材料。历史 build 10 只用 `--history build/app-store/materials-build10` 校验原字节。入口 [app-store/START-HERE.txt](app-store/START-HERE.txt)。工具不访问设备、不联网、不签名、不发布。

统一入口默认 `PADINK_RELEASE_CHECK=daily`；`candidate`/`submission` 必须设置 `PADINK_FROZEN_RELEASE`，分别要求候选绑定与完整提交材料。所有模式检查当前素材一致性。`PADINK_CHECK_SCOPE=ci` 只在干净事件 checkout 使用，排除物理 GPU/codec/SCK 实验，仍运行其他回归与双端无签名构建；`check-provenance.json` 精确记录被检查的源码与工具链，不证明已发布安装包通过。准备的 GitHub workflow 没有上传产物或签名步骤，未经授权不推送私有源码。

既有公开 Beta 私有留存：`python3 engineering/scripts/retain-beta.py build/public-beta/0.3.0-b11-beta.3`，使用已经核对的在线 release 元数据、原源码 ZIP、原构建日志与 dSYM，拒绝 UUID/校验错配，禁止覆盖不同的冻结记录；不重建或发布。

当前正式候选 build 12 的 Mac 分两步：`rc-release.py mac --sign-only` 只签名并留存私有候选；凭据和上传授权齐备后用 `notarize` 提交已冻结签名包并附票据。未公证角色不能进入公开 staging。iPad `ipad` 只 archive/export，不上传 ASC。最新源码已授权公开到 `main`；签名配置、证书、私有安装与发行恢复材料继续 ignored，不随源码提交。
