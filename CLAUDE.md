# PadInk 项目工作约定

## 当前工程与事实

以当前 Git checkout 为开发根目录。对外发布的正式版统一为 PadInk（包括 Beta/RC），公开下载只按 Mac 芯片区分；本机源码开发和内部自用才称 PadInk Dev。正式版 Mac 路径 `/Applications/PadInk.app`；开发版为 PadInk Dev，路径 `/Applications/PadInk Dev.app`。两版 bundle ID、设置、配对 Keychain、USB 端口与 Bonjour 服务分离；旧 PadInk 仍使用正式版的原命名空间。Mac 安装包分别构建 arm64 / x86_64，不用开发版替换正式版。日常开发版 iPad 采用官方 AltStore + AltServer 管理安装与续签；更新命令默认安装 Mac 并准备 IPA，双端 Xcode 安装只在显式 PADINK_IPAD_INSTALLER=xcode 时执行。版本只由 Git commit / tag、App Version / Build 与 RC / Release 管理。

README 是入口，docs 仅保留当前架构、协议、支持范围、安装、开发、发布与隐私文档。archives 只保留完整 Git 恢复备份、Git 无法恢复的最小源码差异、当前 Fixtures 缺少的不可替代原始样本和必要安装恢复材料；归档位置由维护者本机管理，不进入公开仓库。不长期保存阶段、调查、审计、交付和验收叙事、重复日志或截图。

## 代码布局

- `Sources/PadInkCore/`：协议、身份、会话、输入、几何、视频策略与诊断。
- `Sources/PadInkTransport/`：USB、Wi-Fi、安全承载和发现；依赖 Core。
- `Apps/Mac/`、`Apps/iPad/`：协调器、平台输入/视频和 UI；由 SwiftPM app kits 承载。
- `Hosts/`：Xcode App 入口、Info.plist、entitlements、privacy manifest 与图标。
- `Tests/`、`Fixtures/`：长期回归与自足的回放样本。
- `engineering/`：统一的构建、安装、打包、诊断、回放与实验工具；入口见 `engineering/README.md`，不进入产品 App。
- `Config/`：双端版本、身份与签名配置；本机密钥配置独立 ignored。

## 必须保护的行为

1. 输入 A 与视频 B 使用独立流。视频拥塞只降级；B 重建不取消 A 上的 Pencil / Touch。A 丢失才安全释放输入并重连。
2. 捕获时冻结 `InputContext`（attachment UUID + generation）。异步回调、worker 和完成回调必须核对原身份；不能把旧工作套到新会话。视频另有 `VideoDecodeContext.epoch`。
3. 实际和 coalesced Pencil 样本保序，静止终点保留，不发送 predicted 样本。健康路径不为减队列跳过实际样本；过载或过期取消整笔，不能继续发送缺口序列。
4. 本地单调时钟判断年龄和手势截止；跨设备时钟仅用于诊断。超时不可逆，迟到 keepalive 不能复活手势。
5. `VideoGeometry` / `PencilGeometryState` 统一映射，禁止额外乘 Retina scale。几何必须实际呈现才 ready；旧 decoder / present 回调不能开放新会话输入。
6. Pencil 优先于 Touch；取消时释放鼠标/笔接触与 proximity。普通 scroll 明确清除 Command 修饰键，并固定 began 目标。
7. 缩放 worker 同时最多一个物理任务；取消使 permit 无效，不能释放尚未完成任务的占位。调用前 claim 与取消同步，外部 AX / AppleScript / CGEvent 调用不在锁内执行；已经 claim 的一次调用可以完成，取消后不能开始下一次调用。
8. GoodNotes 使用公开 Command + continuous pixel wheel；只允许唯一激活文稿内容区。菜单、编辑、弹窗、目标变化或歧义时拒绝。ended / cancelled 清除连续需求，无惯性尾流。其他应用按公开能力分档，不加私有 magnify 或键盘注入回退。
9. USB listener 的 epoch、退避 retry 和旧回调隔离不得被 UI 状态重写。连接建立与实际画面可用分开呈现；UI 读取既有模型。

## 工作与验证

先读相关实现和测试，做最小范围修改。不要为风格重写已验证输入链路。协议改动同步 `PROTOCOL.md`、MessageRegistry 与 golden 测试。

`./engineering/scripts/build-and-test.sh` 运行 Swift suite、Python checks、Release 诊断、工程生成一致性和双端无签名构建。输出默认在 `build/check/`；可用 `PADINK_BUILD_ROOT` 指定。真实应用回放会接管本机指针，只在明确授权与可用环境下运行；参数见开发者指南。

只更新与任务有关的当前事实。自动测试、安装成功与截图不能代替真实输入、文稿任务或 Apple 分发验收。最低系统、第二套设备与正式分发的未验证项见支持矩阵。

`Config/Signing.local.xcconfig` 是本机 ignored 配置，必须保留，不提交、不放进源码包。公开仓库从 Beta 2 起承载经检查的源码、工程工具、测试和文档；不推送未经检查的本机历史。不要触碰 Keychain / TCC / 配对信任、用户文稿、stash 或改写 Git 历史。改变产品身份、安装双端、发布、上传或 push 时遵循当前会话授权与 Release 文档；本地检查或预览不会自行发布。

`build/`、`.build/` 只存可重建的当前输出。签名恢复只保留当前有效安装包、匹配 dSYM、源码身份与必要 receipt；原始样本先与 Fixtures 去重。不要把历史展开工程、报告和完整 build 移进 archives 长期保存。
