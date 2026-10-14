# PadInk 发布候选与分发流程

命令在源码仓库根目录执行。本文描述候选准备、签名、公证、安装验证和发行操作；本地签名覆盖安装与 Developer ID / TestFlight 分发分别核验。对外发布的正式版统一为 PadInk（包括 Beta/RC），本机源码开发与内部自用采用 development 身份，界面同样显示 PadInk；公开下载不提供开发身份。2026-10-14 已将日用 Mac 统一为 `/Applications/PadInk.app` 的正式 RC build 12，与 iPad TestFlight build 12 配套；旧开发版与重复可启动副本已移至废纸篓。现有配对与权限数据保留，发行恢复材料仍在本机。

当前 `main` 公开最新源码、测试、工具和文档；本次源码提交与安装包发行分别处理；M 系列 build 12 公证 Mac 辅助端随后已发布到 [GitHub Release](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-rc.1-build12)，iPad 仍为受邀 TestFlight，尚未在 App Store 上架。历史 Beta tag 保留原样。已安装 build 12 的原冻结提交仍为 `e8cd70ff8a146f0f1ee1b41992ed11f0bc2eaf89`，App 输入摘要为 `6d912b4a07671f2be558fcb1a8678232667adf3d97454d54bb47bf7ff7929c4e`；公开提交包含后续工具和文档整理，不能替代原安装包的签名与构建身份记录。

## App Store 正式发行（当前本地候选 0.3.0 / build 12）

本轮目标：Mac 仅 Apple Silicon（M 系列 / arm64），后续不再构建、维护或验收 Intel 版本；已生成的 Intel 签名包只作私有历史留存，不提交公证、不进入当前分发材料。公开 Beta 3 的双架构历史资产保持原样。iPad 经 App Store 安装，Mac 经 GitHub Release 提供 Developer ID 签名且已公证的辅助端。首发必要链路是普通 USB 数据线；现有 Wi-Fi 保留，但无线切换不阻挡 USB 首发，商店文案不承诺 Wi-Fi。build 12 是当前正式渠道的本地准备目标，arm64 已通过 Developer ID 公证、附票据和 Gatekeeper；正式 iPad 已签名，TestFlight 上传按下方实时记录区分，尚未提交 App Store 审核。公开 Beta 3 / build 11 是另一分发状态（AltStore + Mac ad-hoc），已有资产保持冻结。历史 build 10 工程/商店资料保留原版本；当前可维护素材在 `engineering/app-store/`，冻结历史输出在 `build/app-store/materials-build10/`。2026-10-14 维护者确认会员注册已通过；正式个人团队及 Developer ID Application / Apple Distribution 私钥身份已在本机核对。正式标识由维护者确认采用 com.padink.mac / com.padink.ipad；发行配置独立于日用配置。正式 iPad App Store profile 与 Apple Distribution 导出已通过；arm64 公证已 Accepted，票据和 Gatekeeper 通过。App Store Connect 免费 App 协议有效，PadInk 记录已创建（com.padink.ipad，SKU padink-ipad，主要语言简体中文）；版本草稿为 0.3.0，设为手动发布。用户已授权 build 12 TestFlight 上传，上传/处理/本人 USB 验证保持各自独立状态。不改变现有开发签名、安装或信任。

维护者已完成此前 RC1 的 USB 真人使用验收（2026-10-13 在当前会话确认）；保留该基线，当前只补视频反馈、Pencil 抬笔/取消及滚动修复的相关回归。该确认不扩展为未记录的逐项结果、外部首装或正式签名渠道通过。Wi-Fi、第二套设备和最低系统继续标为各自未验证；Intel 不在本轮正式候选范围，均不作为本轮发行工程收尾的先决条件。

### 可行性与实际阻碍

| 核对项 | 工程结论与提交条件 |
|---|---|
| 2.1 完整性 | 无账号/服务器；审核需要真实 iPad、Mac、数据线和可下载的公证辅助端。当前无正式签名实机结果、审核演示视频和商店截图，不能声称可以立即提交。无连接时帮助、设置、隐私政策可访问；没有用演示画面替代真实功能。 |
| 2.5 API 与构建 | iPad 使用 UIKit / SwiftUI、Network、Metal、VideoToolbox、Security、CryptoKit 等公开框架；不链接 Mac 的 AppKit、ScreenCaptureKit 或 USB 私有实现。仅 iPad、iPadOS 17+；当前 Xcode 27 / SDK 27 满足上传最低 Xcode 26 / SDK 26 要求。无下载执行代码、广告、分析 SDK、背景常驻权限、ATS 全局豁免或 iPad 自定义 entitlement。 |
| USB | iPad 的公开 NWListener 只绑定 127.0.0.1:42371；Mac 通过系统 `/var/run/usbmuxd` 的 ListDevices / Connect 到达该监听。未调用 lockdownd 调试服务、DeveloperDiskImage、debugserver、Xcode、AltStore；Mac 只选择 ConnectionType=USB。usbmuxd 是未公开接口，保留在独立 Mac 辅助端仍有系统兼容风险，不能推断为 Apple 对正式签名 USB 可用性的保证。必须通过关闭开发者模式的 TestFlight 实测。 |
| 4.2.3 / 4.2.7 | 4.2.3 的另一 App 依赖规则确实需要审核解释；外部 Mac 辅助端不是自动免责，也不是已证明的必拒原因。PadInk 采集主显示器（SCContentFilter display），是通用主机画面镜像，兼容策略只适配输入，不提供特定云应用、软件目录、购买解锁或 iOS 模拟商店。4.2.7 针对特定软件镜像的条件不能不加区分地套成所有 USB 镜像必拒；USB 也不能被称作已经满足其 LAN 条件。向 Apple 如实说明直连用户自己的 Mac，最终归类以审核为准。 |
| Mac 安装与权限 | 非 Mac App Store，保留非 sandbox 和 hardened runtime。屏幕录制用于主屏镜像；辅助功能用于公开 CGEvent / AX 输入；仅 PowerPoint 缩放需要 Apple Events 自动化 entitlement。不给辅助端 root、kext、私有 HID 能力或远程安装功能。正式下载首次启动需实测 Gatekeeper、公证票据、屏幕录制和辅助功能授权、拒绝及恢复。VPN 保持开启。 |
| 5.1 隐私 | 两端可打开政策；实时画面/输入不归档、不上传维护者；USB 有配对认证但应用帧未额外加密，Wi-Fi 使用系统 TLS。本机偏好、Keychain 身份/信任和有限诊断；主动导出、分享另行披露。privacy manifest 声明 UserDefaults CA92.1、BootTime 35F9.1/8FFB.1、容器文件元数据 C617.1。无 tracking/第三方 SDK；不能把 manifest 当成 App Privacy 问卷的替代。 |
| 加密与依赖 | SwiftPM 无外部依赖，App 不携带 Replay / WebProbe 工具；使用系统 CryptoKit 的 X25519、HKDF、SHA256、HMAC 和 Security / Network 的 TLS PSK，未嵌入 OpenSSL 或自实现算法。iPad `ITSAppUsesNonExemptEncryption=NO` 表示当前仅系统加密服务的文档豁免，不表示未使用加密；发布者核对所选地区的出口/进口及可能申报要求，变更加密依赖后重新审查。 |

### 身份、数据和配对

正式 namespace 不变：USB 42371、Bonjour `_pnk2._tcp`、Keychain service `dev.padink03.trust`；Dev 的 42372 / `_pnk2-dev._tcp` / `.trust.development` 保持隔离。协议与配对算法没有变更。

当前个人源码配置的 iPad ID 是 `dev.padink03.xuk77wlk49.ipad.development`（正式 variant 没有 `.development`）；历史 AltStore 基础 ID 是 `dev.padink.altstore.ipad`，AltStore 重签可能改写实际标识。提交前从各个**实际安装包**的 Info.plist / profile / 签名读取真实 Bundle ID、Team ID、App ID prefix、Keychain group，不能按源码值推断侧载结果。当前正式 ID 已由维护者确认采用 `com.padink.mac` / `com.padink.ipad`，不自动沿用其他团队 ID。

Keychain account 包含 bundle ID，iPad 默认 access group 受签名 App ID prefix 限制。Dev/AltStore/另一团队转 App Store **不能保证**容器偏好或密钥迁移；默认按独立安装和重新配对处理，保留旧 App，确认新 App 可用后再自行处理旧安装。不要拷贝私钥、扩大共享 Keychain 或清空全局信任。新 Mac 签名身份也可能需要重新授权 TCC / Keychain。正式团队同 Bundle ID 的 TestFlight → App Store / 正式覆盖升级才是应验证的保留设置与配对路径。文稿由 Mac 目标应用保存，不存于 iPad PadInk 容器。

同一上传二进制依据系统 receipt 路径区分 TestFlight 与 App Store 安装说明（不是购买验证）；生产 receipt 显示正式渠道。TestFlight / App Store 不解析并发送 profile 到期提醒；免费个人安装保留原提醒。TestFlight 90 天测试有效期由 TestFlight 管理。

### 商店元数据与审核说明草稿

- 名称：PadInk；副标题：用 Apple Pencil 操作你的 Mac；首选类别：效率；关键词：手写,触控,镜像,批注,Mac,Apple Pencil,USB。
- 描述：PadInk 将你自己的 Mac 主屏显示到 iPad，让你用 Apple Pencil 书写，用手指点击、拖动、双指滚动和缩放。文稿由 Mac 上的目标应用保存。需要 macOS 14 或更新版本的 Mac、单独安装的 PadInk Mac 辅助端、iPadOS 17 或更新版本及 USB 数据线。手写需要兼容的 Apple Pencil。Mac 首次使用需允许屏幕录制与辅助功能；部分应用缩放还需允许自动化。iPad 正式版由 App Store 安装，无需开发者模式、AltStore、Xcode 或签名续期。支持范围以实际验收为准。
- 政策 URL：https://github.com/double-u-zw/PadInk/blob/main/docs/PRIVACY.md；支持 URL：https://github.com/double-u-zw/PadInk/issues。当前工作树政策/UI 需随批准的源码发布到该地址后再验证；现有公开页面仍是旧版。确认未登录可访问，不把本地文件 URL 填入商店。
- App Privacy 初步答案：不收集数据（画面与输入仅在用户自有设备间实时处理；没有向开发者或 SDK 自动传输）。必须同时确认可选诊断求助符合 Apple 对可不披露的客服数据条件；不符合时在 App Store Connect 披露相应数据，不能机械勾选。无账号，无账户删除入口，无 ATT/广告标识符。
- 年龄分级按 Apple 当前问卷据实填写；不用“儿童”分类，不因本工具可显示用户桌面就捏造内容库。选择销售地区前核对 DSA 交易者信息及各地区手续（包括拟在中国大陆提供时所需备案）。价格和法律联系信息由账户持有人填写。

审核备注英文正文（提交前追加**这次已公证 Mac 资产的精确下载 URL、真实硬件演示视频 URL、审核联系方式**，未准备这些材料不可提交）：

> PadInk is a native iPad client that mirrors the primary display of the user's own Mac and sends Apple Pencil and touch input back to that Mac. Mac applications execute and save documents on the Mac. PadInk does not provide a cloud computer, application catalog, software purchasing interface or an iOS-like remote environment. A separately installed Mac companion is required for screen capture and input; it is distributed through GitHub Releases with Developer ID signing and Apple notarization. No additional iPad app, developer mode, Xcode or sideloading tool is required for the distributed iPad client. Please connect the unlocked iPad to the Mac with a USB data cable, open both clients, allow macOS Screen Recording and Accessibility, and approve the device pairing on both screens. Open a document and select a pen tool on the Mac, then test Apple Pencil writing and two-finger scrolling/zooming on the iPad. There is no account or login. Privacy and connection help are available in Settings before connecting. The attached video demonstrates this exact candidate on real hardware.

备注中的“无需开发者模式”及视频说明只能在本候选真正完成对应实测后使用；目前为预备文案。审核视频约 2–3 分钟：从 TestFlight 安装、已关闭开发者模式的设备开始，展示 Mac 签名/权限、Finder 信任（若系统询问）、USB 双端配对、主屏含两个不同应用、Pencil 写擦、双指滚缩、保存重开、拔线恢复和忘记设备。遮掉私人文稿与账户；不要用 fixture 截图或旧 build 冒充。商店截图另取真实 iPad 使用画面；审核附件可展示 Mac 配置，App Preview 遵守 iPad App 画面要求。

### 会员生效后与提交前的必要验收

1. 账户持有人确认会员/协议生效、团队、稳定双端 Bundle ID，创建 iPad App Store Connect 记录。确认价格、地区、隐私/年龄/加密问卷、法律联系与审核联系人。准备 Apple Distribution + App Store profile、Developer ID Application + 本机 notarytool profile；**经用户确认后**才填写/使用正式身份，不覆盖 `Signing.local.xcconfig`。
2. 检查本改动并固定源码，准备新 clean RC。沿用下文 `rc-release.py prepare/mac/ipad/check`：Mac 公证会上传到 Apple；iPad 只导出本地上传候选，`destination=export` 不上传、不审核、不发布。导出检查 profile、二进制实际 entitlements、团队、get-task-allow=false、dSYM、SDK 和双端源码身份。需要首次 TestFlight 上传时另按用户授权操作；不自动提交 Beta Review / App Store Review。
3. **核心发行门槛**：TestFlight 新安装，iPad 关闭开发者模式；Mac 在退出 Xcode/AltServer 后独立运行（无需卸载），不挂载开发镜像、不启动调试服务，VPN 保持开启。用普通数据线完成 Finder 系统信任、双端配对、画面、Pencil、双指和文稿保存。记录实际团队/ID/版本，拔插、前后台、锁屏恢复以及 已有 RC1 USB 基线保留，先补变化与渠道差异，有退化迹象再补长时间使用。若 USB 失败，先诊断 usbmux 普通 Connect 与 loopback 到达情况；不以开发安装、Wi-Fi 或模拟器通过作为替代。
4. 从下载的已公证 Mac 资产安装，确认 Accepted + staple + Gatekeeper；权限拒绝/恢复、重启 App 和配对可用。本轮只验证实机 Apple Silicon；Intel 不在本轮正式候选范围，最低系统仍明确未验收，不扩张兼容承诺。
5. 从个人版本迁移和正式同身份升级分别验收；个人迁移允许重新配对，同正式身份覆盖更新应保留开关/配对。正式 Mac 与正式 iPad 相连，Dev 配对不串用；忘记设备后不得继续自动连接。
6. 政策/支持 URL 与公证下载未登录可用；提交截图、视频和备注对应同一候选。完成当前年龄/加密/地区手续、TestFlight 验收后请求用户最终确认，才提交 App Store 审核；公开发布另行确认。

商店素材与会员生效后命令清单见 [engineering/app-store/START-HERE.txt](../engineering/app-store/START-HERE.txt)。`store-materials.py` 只验证字段与本地素材并打包，不联网、不安装、不签名；`--release <干净候选> --require-ready` 在联系人、正式下载、真人验收与截图待确认时失败。现有公开下载仍为 AltStore/未公证 Beta 3，本地新版政策／支持／安装文案需获得公开更新授权后部署，不需公开本轮源码。

本机检查入口：`PADINK_BUILD_ROOT=build/app-store/check PADINK_BUILD_SIMULATOR=1 ./engineering/scripts/build-and-test.sh`。产物 `build/app-store/check/dd/Build/Products/Release{,-iphoneos}/PadInk.app` 为**未签名**双端 Release，配有 dSYM 和 `store-bundle-check.json`；它们不能代替 TestFlight、公证包或正式上架验收。iPad 模拟器 App 使用本地 ad-hoc 临时签名（不使用证书或更新 provisioning），以支持模拟器 Keychain，位于同一 Products 的 `Release-iphonesimulator/PadInk.app`，模拟器仅用于启动/UI 检查；Metal 呈现回调在模拟器 SDK 不可用时使用 GPU 完成回调，不产生真实显示延迟统计，真机呈现路径保持不变。`check-store-bundle.py` 只作工程预检，不是 Apple 审核、私有 API 完整认证或正式签名证明。

参考： [Apple 当前审核指南](https://developer.apple.com/app-store/review/guidelines/)、[上传 SDK 要求](https://developer.apple.com/news/upcoming-requirements/?id=02032026a)、[required reason API](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)、[系统加密出口合规](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)、[App Privacy 定义](https://developer.apple.com/app-store/app-privacy-details/)。规则核对于 2026-10-12；工程可行不等于获准上架。

## 当前冻结候选与发布者待办

2026-10-13 已发布 **[0.3.0 Beta 3 / build 11](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-beta.3)**：M 系列／Intel 的未公证 ad-hoc Mac 测试包、共用 AltStore IPA、校验值与用户文档。535 项 Swift 测试（6 项跳过）零失败，双端 Release 构建与包内身份／校验通过；维护者设备的 Dev build 10 USB 原位更新、设置与原配对保留，Ecru 激光笔试用反馈未见问题。build 11 对外身份、第二套设备及完整长时间文稿仍待真人反馈。原 build 10 App Store 基线与 Beta 2 资产保留。

本次仅发布安装包和用户文档，源码／签名配置／设备备份／诊断／dSYM 未上传；GitHub tag 的 Source code 附件仍为既有公开源码及文档更新。实际构建输入与本机私有快照按包内 source digest 核对，不能把公开 tag 当作本次修复源码。Beta 3 发布时尚无 Developer ID 公证包或 TestFlight / App Store 构建；当时本机两端开发身份保持 build 10，未替换成公开身份。

此前已公开版本为 **0.3.0 Beta 2 / build 9**；截至 2026-10-12 本机已安装的 PadInk Dev 为 build 8，其 AltStore 安装、启动与手动续签已在 2026-10-12 核对。Beta 2 下载和实际状态以 [发布页](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-beta.2)为准；build 9 的完整真人验收尚未完成。已冻结的正式 RC 仍为 `build/rc/0.3.0-rc.1/` 的 RC 1 / build 6；下文 RC 2 命令仅为后续示例。Beta 2 公开当前源码快照、测试与工程工具；匹配 dSYM、签名与恢复材料留在本机，不公开未经检查的本机历史。

冻结源码与验证无签名构建后，安装分发状态仍为待完成。下面事项由发布者准备账户、提供设备并亲自验收；尚未执行的结果填写“未测”。

| 待办 | 完成标准 |
|---|---|
| 当前包的 USB 文稿与稳定性 | 按真人清单 U1–U7 / R1–R4 完成安装、配对、四角定位、写擦滚缩、保存重开、30–60 分钟使用，以及断线、后台、休眠、焦点与权限恢复；记录双端 build/source 和目标应用版本 |
| Wi-Fi 与切换 | 不作为 App Store USB 首发门槛；承诺无线功能前再完成 W1–W3，USB 结果不能替代 Wi-Fi 结果 |
| 应用与设备范围 | 实际使用的应用填写 A1–A5。Intel、最低 macOS 14 / iPadOS 17、第二套设备仍需 E1–E3；未测环境继续注明未验证 |
| 正式团队与 App ID | 准备有效 Apple Developer 团队，确定稳定的 Mac/iPad bundle ID、iPad App Store Connect 记录，填写 ignored 的 `Config/Release.local.xcconfig`。保留原开发签名配置；不提交证书、私钥或凭据 |
| Mac 签名公证 | 准备 Developer ID Application 证书及 Keychain 公证 profile；从冻结源码执行 `mac`，核对 Accepted、staple、签名、Gatekeeper 和本轮声明的 arm64 包；通过真实下载首次启动再测试权限、USB 与文稿 |
| iPad TestFlight | 准备 Apple Distribution / App Store profile；执行 `ipad` 后由发布者上传 App Store Connect，等待处理和所需 Beta Review；从 TestFlight 真正安装并与正式 Mac 配对验收 |
| 元数据与审核材料 | 填写支持与隐私入口、App Privacy 与加密合规问卷、截图、审核联系方式、配对步骤和演示；准备审核员可下载的公证 Mac 包。按真实行为填写，不以脚本替代问卷判断 |
| 身份迁移与覆盖升级 | AltStore/个人团队转正式团队单独记录权限、钥匙串与配对变化；首次正式安装后，再对同一正式身份做覆盖更新，核对设置、配对、版本与诊断。不得把首次迁移写成同身份升级通过 |
| 最终分发 | 运行 `check --require-assets --verify-platform`，归档匹配 dSYM/receipt，填写候选说明中的实际验收结果与真实 TestFlight 入口，再上传检查过的公开资产。正式 App Store 上架独立处理 |

真人记录模板见[试用验收清单](试用验收清单.txt)。正式包验收用 Developer ID / TestFlight 的真实安装流程；清单中 AltStore 开发者模式与续签项目不适用时记“不适用”，不能要求 TestFlight 用户按 AltStore 流程安装。

源码冻结后若修复产品代码或改变构建配置，应递增 build 并准备新候选。签名和上传使用当前候选；额外证书/profile 不写入源码，冻结的程序、源码身份和 tag 不变。已发布 ZIP 仅修订随包说明时，单独记录 documentationRevision 与 documentationSourceCommit，逐字节核对 DMG / IPA 未变，更新包内及发布页校验值，并在发布说明注明日期与无需重装。

## 本机开发版、对外正式版与 Mac 芯片包

| 项目 | 开发版 | 对外正式版 |
|---|---|---|
| 名称与 Mac 安装目录 | PadInk Dev / PadInk Dev.app | PadInk / PadInk.app |
| 默认使用场景 | 日常源码构建、诊断与内部试验 | 给使用者的 Beta/RC 与后续稳定分发 |
| build variant | development | release |
| bundle ID | 正式基础 ID 后附 `.development` | 当前正式 ID；AltStore 固定 dev.padink.altstore.mac / .ipad |
| 设置与恢复材料 | 独立 bundle domain / 目录 | 保留当前正式版 domain / 目录 |
| 配对 Keychain service | dev.padink03.trust.development | dev.padink03.trust |
| USB loopback / Bonjour | 42372 / _pnk2-dev._tcp | 42371 / _pnk2._tcp |

两版可同时保留，首次 PadInk Dev 需要独立授权与配对，不拷贝已有版的密钥或设置。双端须选择同一版；芯片包共用该版身份。`release` 指对外 PadInk 的构建身份，`development` variant 指本机 PadInk Dev；渠道 `rc` / `development` / `release` 与 `altstore` / `direct` / `testflight` 是工程元数据。对外名称统一为 PadInk；Beta/RC 表示发布阶段，验收范围按事实说明，不让使用者选择开发版。

当前正式候选仅构建 arm64（M 系列）Mac App；文件名、二进制、dSYM 与候选清单声明的架构必须匹配。Developer ID 路径对声明的目标架构 archive、签名、公证、附票据并生成 ZIP，全部声明目标通过后才允许本地公开 staging。历史 AltStore 双架构 DMG/ZIP 保留原记录，Intel 不在本轮候选范围。正式签名工具只使用正式版身份。

例：`PadInk-0.3.0-b7-mac-arm64.dmg`、`PadInk-0.3.0-b7-mac-x86_64.dmg`；开发版为 `PadInk-Dev-0.3.0-b7-mac-arm64.dmg` 与 `...-x86_64.dmg`。选“关于本机”中的芯片：Apple M 系列选 arm64，Intel 选 x86_64。

## 分发选择

| 场景 | Mac | iPad | 使用者需要什么 |
|---|---|---|---|
| 首次 RC / 持续 Beta | Developer ID Application 签名、Hardened Runtime、Apple notarization 后附票据的应用 ZIP | App Store Connect → TestFlight | 普通 Apple 账户和 TestFlight，不需要 Xcode / Developer Program / 开发者模式 |
| 正式普通用户 | 同一发行团队的公证包，GitHub Release 或产品下载页 | App Store | 下载 Mac 包，App Store 安装 iPad App |
| 开发者本机 | Apple Development，原 `Signing.local.xcconfig` | 免费 Personal Team 或付费团队的开发签名 | Xcode；免费团队仍每 7 天重新配置安装 |
| AltStore 免费账号试用 | 当前为 ad-hoc 签名的 Mac 测试包，首次打开需用户确认 | 官方 AltStore Classic 安装 IPA 并续签 | 使用者无需 Xcode 或付费会员；维护者需 Xcode 构建。正式 Mac 分发仍须补 Developer ID 公证 |
| 少量已登记测试设备的备用路径 | 同上公证包 | 付费团队 Ad Hoc | 维护者收集 UDID、登记设备并提供适用签名包 |

这是当前产品最短的分发路线：Mac 跨应用输入、Apple Events 和 `/var/run/usbmuxd` 访问保持既有实现；Mac App Store 的 App Sandbox 要求与这些能力存在冲突，没必要为首次 RC 改写已经稳定的产品。[Apple Developer ID](https://developer.apple.com/developer-id/) · [公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

iPad TestFlight 解决免费签名每周续期和让使用者配置 Xcode 的问题，但每个构建最多有效 90 天，外部测试可能需要 Beta App Review；长期公开产品走 App Store。内部测试限有 App Store Connect 访问权的团队成员，不能把所有普通测试者加成开发团队来绕过外部审核。[TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

Ad Hoc 可以不让使用者装 Xcode，但需要维护者登记设备并管理配置文件，不适合作为普通用户长期下载。Apple 当前按设备家族每会员年最多登记 100 台，删除登记设备不立即恢复额度。[设备规则](https://developer.apple.com/help/account/devices/devices-overview) · [Ad Hoc 配置](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile)

免费账号试用另走官方 AltServer / AltStore Classic，不自研认证与签名，保留约 7 天签名期限；流程见安装指南。它与本文 Developer ID / TestFlight 正式发布路径分别验证。不做 Enterprise 对外分发，也不为首个 RC 维护自动更新服务或 Mac App Store 沙盒版本。首次 Mac RC 手动覆盖安装，后续有实际用户规模再决定自动更新。

## 当前候选、冻结材料与检查分层

正式团队证书已可用时可先 `mac --sign-only`，生成 `maintainer-mac-notary-candidate` 私有资产，明确未公证且不是公开安装包；无需公证凭据，也不上传 Apple。获得公证上传授权、设置 `PadInk-Notary` 凭据后，`notarize` 复用这些精确签名字节，Accepted 后附票据生成公开角色资产；拒绝或失败保持私有候选，不重新构建、不冒充通过。iPad `ipad` 只导出 Apple Distribution 上传候选，ASC 上传另需授权。


- 当前公开安装包是 Beta 3 / build 11，公开 tag `v0.3.0-beta.3` 指向文档/公开基线提交 `281148b50e39a90ceec513bf53d3ca4531bc8a48`；实际 App 构建基线是 `5b08d4130c388cf0571ba1eaf742fd8823e50803`，包含私有未提交修复，App 输入摘要为 `331b3422317329d12cfaf1fb9db55750cb807fb8784b1ca6fb12070b4e9d2480`。公开 tag 不能复现这个安装包。
- 精确源码 ZIP 已保存在本机 `build/public-beta/0.3.0-b11-beta.3/private-source/`；同目录旁 `private-retention/` 保存公开资产校验、两种 Mac 和 iPad 的匹配 dSYM、构建覆盖设置与二进制中的 SDK/Xcode 信息。只补缺少的符号留存，不重建已发布包。该私有目录不进入 Git 或公开资产。
- 当前正式候选递增至 build 12，承载已更新的新图标及统一 PadInk 名称，既有输入/会话/视频机制沿用当前源码。build 11 安装包和商店输出保持冻结。build 12 在本机独立的私有干净 checkout 冻结为提交，不改写日用工作区历史，不推送；源码 ZIP 与实际签名输入绑定。
- 日常入口 `build-and-test.sh` 校验当前素材版本/目标、回归及双端无签名构建，账户/真实截图待确认不会冒充通过，也不阻塞本地工程检查。`PADINK_RELEASE_CHECK=candidate PADINK_FROZEN_RELEASE=<冻结目录>` 进一步绑定完整源码；`submission` 再要求干净正式候选及完整商店字段。错误不会被跳过。
- `store-materials.py --history build/app-store/materials-build10` 只核对历史字节，禁止与 `--out`、`--release` 或 `--require-ready` 混用。当前导出需 `--release <冻结目录> --out <build 下新目录>`；提交检查需 `--release <干净候选> --require-ready`。
- `.github/workflows/check.yml` 只准备在已获授权的仓库使用，当前不推送。CI 检查事件 checkout（PR 为合并提交），记录 commit、App 输入摘要和完整工程树摘要；云端不执行物理 GPU/codec/SCK 实验，不使用签名秘密或上传产物。旧公开基线的绿色结果只属于该基线，不能替代当前私有树、本机包或真人结论。

## 历史公开测试版（0.3.0 Beta 2 / build 9）

`double-u-zw/PadInk` 从 Beta 2 起公开经检查的当前源码、测试、工程工具、文档和安装包。Beta 2 以 GitHub pre-release 发布；实际状态见 [Beta 2 发布页](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-beta.2)，反馈用 [Issues](https://github.com/double-u-zw/PadInk/issues)。Beta 1 / build 5 的旧资产保留，不重新生成或覆盖。

公开资产为 `PadInk-0.3.0-b9-Beta-arm64.zip`、`PadInk-0.3.0-b9-Beta-x86_64.zip`、对应两份独立 DMG、共用 `PadInk-AltStore.ipa` 及外层 `SHA256SUMS`。完整 ZIP 带该芯片的 Mac 包、iPad IPA、安装步骤、使用教程、真人清单及支持/隐私说明。官方 AltServer 使用固定官方链接，不上传为 PadInk 资产。

双端渠道为 `rc`、分发为 `altstore`、产品身份为 `release`；这表示测试成熟度与产品身份，稳定版尚未发布。包内 `candidateKind = public-beta` 和 `publicationStatusAtPackaging = prepared-not-uploaded` 记录打包时状态；GitHub 实际上传资产与链接另核对，不改写已冻结包。

发布仅上传检查过的安装材料及文档。公开 tag 和 GitHub 自动生成的 Source code 附件对应本次检查后的源码提交；签名配置、诊断、原始日志、设备备份与 dSYM 不上传。Beta 1 的历史 tag 仍仅包含当时的发布文档。build 9 的独立安装、文稿任务、长时间使用、Wi-Fi、自动后台续签、过期恢复和覆盖升级仍待真人验收，Intel / 最低系统 / 第二套设备明确标记未验证；开发版 build 8 的安装与手动续签记录不能替代这些结果。Developer ID 公证及 TestFlight 仍为后续分发工作，不宣称本 Beta 已完成。

## 受邀试用包的本地准备流程

以下命令仅生成本地私下分享材料，不上传。它是 **AltStore 受邀试用候选**，与下文要求干净提交和 Apple 正式分发的 RC 区分。正式版身份的双端构建显式使用 `rc` 渠道、`altstore` 分发；本机开发配置仍默认 `development / developer`，正式版 AltStore bundle ID 保持原值，开发版附 `.development`。

```sh
./engineering/scripts/build-and-test.sh
python3 engineering/scripts/package-altstore.py --variant release --out build/share/candidates/0.3.0-b7-trial.1
# 开发版使用独立目录与身份
python3 engineering/scripts/package-altstore.py --variant development --out build/share/candidates/0.3.0-b7-dev.1
# 源码尚有未提交改动时，私下留存精确恢复快照，不放进试用安装 ZIP
python3 engineering/scripts/rc-release.py prepare --preview --out build/trial-private/0.3.0-b7-trial.1/source
python3 engineering/scripts/rc-release.py check build/trial-private/0.3.0-b7-trial.1/source
```

给测试者的材料是同一输出目录内的 `PadInk-0.3.0-b7-Test-arm64.zip` 或 `...-x86_64.zip` 和官方 `AltServer-1.8.1.zip`。ZIP 包含 对应单架构 Mac DMG、AltStore IPA、“先读我”“安装说明”“真人验收清单”、支持与隐私等文档快照，以及版本清单和 SHA256SUMS。Mac 为未公证 ad-hoc 测试包；iPad 安装/续签由官方 AltStore 处理。脚本拒绝覆盖已有候选，重新交付时递增 build 或指定新目录。

`VERSIONS.json` 标记 `published = false`、`newBuildDeviceTested = false`，并记录当前源码是否未提交；Git revision 是基线提交，source digest 对应构建输入。SHA256SUMS 覆盖安装资产和文档。源码快照、构建日志与匹配 dSYM 由维护者在 `build/trial-private/` 留存，不发给普通试用者，不复制本机签名配置。公证、App Store 上传和上架条件仍按后续正式流程执行。

真人项目与结果模板见[试用验收清单](试用验收清单.txt)：先独立安装、USB 真实文稿和 30–60 分钟使用，再验证 Wi-Fi/插拔恢复、权限、续签和同身份更新。每项填写通过/失败/未测/不适用及设备、版本、连接方式；记录只能证明对应包和环境，旧 build 的 USB 或续签记录不能自动升级为本包通过。日常使用 PadInk Dev 可以验证对应源码的体验；记录须注明开发版身份和实际 build，正式包仍须验证自己的安装、授权、配对和分发流程。尚未实施的项目保持“未测”。

## 不应被打包成功掩盖的 Apple 风险

- Mac 的 `USBMux.swift` 通过 POSIX socket 访问系统 usbmuxd，没有链接私有 framework；**这不证明 usbmuxd 的协议属于 Apple 对第三方承诺的公开接口**。目前有真机功能证据，仍是未来系统变化的兼容风险。Developer ID / notarization 也不等于 Apple 认可这项接口或全功能验收，首次正式签名包必须再试 USB 与自动切换。
- iPad 使用公开 Network.framework 与本地 loopback 监听；审核需说明它是 Mac 的手写/触控伴侣。App Review 的 2.5.1 与 4.2.3(i) 仍适用，需提供可下载公证 Mac 包、权限说明、配对步骤与演示视频，使审核员能检查完整功能；不承诺 TestFlight / App Store 必然通过。[审核规范](https://developer.apple.com/app-store/review/guidelines/)
- Wi-Fi 用 Network.framework 的 TLS 1.2 PSK，配对和认证用 CryptoKit。ATS 只约束 URL Loading System，不给低层 Network.framework 提供自动保护；当前不需要为了上传增加 `NSAllowsArbitraryLoads`，也不为发布重设计 TLS。[ATS 说明](https://developer.apple.com/documentation/security/preventing-insecure-network-connections)
- 两端有 privacy manifest：UserDefaults 用于本 App 设置；单调时钟用于计时与应用内事件时间。manifest 不是 App Store 隐私问卷的替代品。应用传给已配对 iPad 的画面与输入、主动提交的诊断、TestFlight 自身反馈必须在说明中如实区分。[Required reason APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- TLS、ECDH/HKDF/HMAC 都涉及加密。发布者在 App Store Connect 回答 export compliance 问卷，确认地区和是否需要文件；当前 iPad 已按仅使用系统加密服务配置 `ITSAppUsesNonExemptEncryption = NO`；发布者仍需核对问卷、地区及依赖变化，不能因该字段跳过判断。[Apple 加密申报](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)

## 版本、源码与兼容约定

`Config/Version.xcconfig` 是双端版本的唯一来源：当前配置为 `MARKETING_VERSION = 0.3.0`、`CURRENT_PROJECT_VERSION = 11`、源码开发默认渠道 `development`，候选脚本构建时明确覆盖为 `rc`。正式 Apple 版本字段不带 `-rc`；发布标题可使用 `0.3.0 RC 2`，维护者批准后 Git tag 可使用 `v0.3.0-rc.2`，发布 tag 在实际发布时创建。

每次上传 App Store Connect 使用新的 build number；同一候选的 Mac 和 iPad 使用同一 version/build/源码 revision 与 digest。`source commit` 标识 Git revision；SHA-256 digest 标识参与构建的源码内容。未提交 diff 用明确的 dirty 预览身份，不冒充可复现的正式 RC。版本/渠道/发行方式与完整源码身份在 About / 设置、诊断及 manifest 中可查。

连接兼容以 HELLO 的 `minWireVersion / maxWireVersion` 协议范围判断，build number 或 source digest 的不同不自动表示协议不兼容；当前 PINK/2 envelope 的 wire version 为 3。RC 推荐同次发布双端组合；协议没有重叠时拒绝连接并提示更新。不要把版本字符串相等当作兼容策略，不为发布新增另一套 Session 协商。

正式 App ID 必须固定由发布者选择的 bundle prefix、团队与 iPad App Store Connect 记录，不使用每位用户自己的团队前缀。开发配置 `Config/Signing.local.xcconfig` 继续独立；正式配置从 `Config/Release.example.xcconfig` 创建本机 `Config/Release.local.xcconfig`：填写 `DEVELOPMENT_TEAM`、`PADINK_BUNDLE_PREFIX`、两端 bundle ID、`PADINK_MAC_SIGN_IDENTITY`、`PADINK_IPAD_SIGN_IDENTITY` 和 `PADINK_NOTARY_PROFILE`。最后一项只是已存入本机 Keychain 的 profile 名称，不是密码；不把付费证书/配置写进仓库。

## 当前可直接运行的候选命令

```sh
# 工作区含未提交改动时：只生成标明 dirty 的材料预览
python3 engineering/scripts/rc-release.py prepare --preview --out build/rc/preview
python3 engineering/scripts/rc-release.py check build/rc/preview

# 冻结干净已提交源码后生成正式候选
python3 engineering/scripts/rc-release.py prepare --out build/rc/0.3.0-rc.2 --notes <本机候选说明文件>

# 付费账户、固定AppID与本机Release配置准备好后，逐端生成
python3 engineering/scripts/rc-release.py mac --release build/rc/0.3.0-rc.2 --arch arm64
# 当前候选只声明 arm64；历史 Intel 资产不进入本轮 staging
python3 engineering/scripts/rc-release.py ipad --release build/rc/0.3.0-rc.2
python3 engineering/scripts/rc-release.py check build/rc/0.3.0-rc.2 --require-assets --verify-platform

# 只暂存可公开资产；不上传GitHub，源码附件可用--include-source选入
python3 engineering/scripts/rc-release.py public-assets --release build/rc/0.3.0-rc.2 --out build/rc-public/0.3.0-rc.2
python3 engineering/scripts/rc-release.py check-public build/rc-public/0.3.0-rc.2 --verify-platform
```

`prepare` 固定候选源码身份和当前文档、生成清单与校验值，并临时生成发布说明草稿；需要正式版本说明时用 `--notes <说明文件>` 输入。源码 docs 不长期保存历史 RELEASE_NOTES；`mac` 构建 Developer ID App，提交 Apple 公证并校验 Accepted、附票据，再打 ZIP；`ipad` 生成 archive 和 App Store Connect 本地导出材料，不上传 ASC、不创建 TestFlight 邀请。公证步骤会向 Apple 提交包，并需要已配置的 notarytool Keychain profile；没有证书/凭据时应停在明确失败，不能回退为 ad hoc 签名冒充发行。

`check` 的成功范围由参数决定：预览检查通过不代表两个 App 已存在，文件存在不代表 TestFlight 已经可以安装，Mac 公证成功也不代表 iPad 审核完成。读 manifest / ASSETS 的实际状态，不用目录名推断发布完成。正常本地最终核对用 `--require-assets --verify-platform`；前者要求两端候选资产，后者独立解压验证 Mac ZIP 的签名、票据与 Gatekeeper，以及 iPad IPA 的 Apple Distribution 签名、App Store profile、metadata 和与 archive 记录匹配的 UUID。Apple 上传验证、处理与 TestFlight 安装另做。`--require-distributable` 会明确失败，因为这个工具不核验 TestFlight 已可安装；不是候选构建必经命令。App Store Connect / TestFlight 的安装事实需要维护者独立记录，不能编辑清单猜测成功。

## GitHub Release 的公开与私有材料

正式 Developer ID / TestFlight 路径创建 GitHub **pre-release** 前，维护者完成双端实际安装与下表核对。当前 AltStore 公开 Beta 按上文授权与明确未测范围发布。候选目录同时包含 iPad 上传材料，用 `public-assets` 生成单独公开目录，并用 `check-public` 再检查；不把整个候选目录压成用户下载包。这两项不创建 Release，也不证明 TestFlight 已可安装。

正式分发产物名称应包含实际 version/build 与用途。Developer ID 包、TestFlight 上传候选和源码 ZIP 分开；源码与 dirty 预览不是普通用户安装包。

| 材料 | 公开 Release | 维护者私下保留 |
|---|---|---|
| Mac 已公证并附票据的 App ZIP | 是，明确 version/build 与目标架构 | 同一份包、公证记录 |
| README 与当前七份文档 | 是，可放文档附件或稳定链接 | 候选时的快照 |
| PUBLIC-MANIFEST.json、SHA256SUMS、ASSETS.json | 由 public-assets 生成，只列可公开材料 | 候选 manifest.json、全构建清单与核对记录 |
| iPad TestFlight 邀请、适用 Mac 版本、到期限制 | Release 正文给真实有效链接；没有链接就不能写可安装 | ASC build ID、上传与审核结果 |
| 源码 ZIP | 可选，指定同一提交；不是安装包 | 构建对应源码 |
| TestFlight 候选 `.ipa`、两端 `.xcarchive` / `.dSYM` | 否；AltStore 路径的独立未签名 IPA 可另行提供下载 | 是，按 version/build/source 和二进制 UUID 归档 |
| 本机签名配置、证书/私钥、Keychain、profile凭据、安装日志、测试诊断 | 否 | 必要时本机保管，不能随源码包打包 |

后续正式 Mac 包只构建 arm64 单架构二进制，不提供 Intel 版本；两端 archive 保留与二进制 UUID 匹配的 dSYM。正式候选源码包绑定干净的提交，不含未提交 diff、签名配置、配对密钥或验收文件；working-tree preview 源码包显式包含当前源码改动，仅用于预览。Xcode archive / dSYM 要与实际发行二进制 UUID 匹配，保留期限至少覆盖此版本的支持期；缺失或不匹配就无法可靠还原 crash stack。[Apple crash 诊断](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs)

## 升级、身份和数据保留

PadInk 不保存文稿；文稿在 Mac 目标应用里。PadInk 的偏好在本 App UserDefaults，设备身份/信任在本机 Keychain，诊断由使用者主动导出。正常升级不删除这些数据，不重置配对。

保留数据的发布条件：固定 team、bundle ID、Keychain 访问权限/代码签名要求、服务与 account 名，存储格式兼容，覆盖安装。**从 Apple Development 改为 Developer ID 即使同 team / bundle ID，Mac Keychain ACL 与 TCC 授权仍须实际检查，不能仅凭代码宣称无缝。** 免费测试者的个人团队与正式团队/bundle通常不同，首次进入正式包重新授权、配对，不自动导出或搬运信任私钥。

升级前保存文稿、退出 Mac App；覆盖 Mac 包、更新 iPad。优先发布两端一起更新的组合。首次 RC 不承诺跨版本降级，不引入会破坏旧读者的存储迁移；若以后更改存储格式，必须先定义向后兼容和回退边界。Mac 可由维护者指定已公证旧包，iPad 只在 TestFlight 构建仍有效时选旧构建；App Store 不是任意旧版包仓库。

## Release 日志、诊断与 crash

Release 用户入口保留连接状态、权限、配对、版本与主动导出诊断。构建细节便于支持，不需要开发者测试入口；逐笔回放、强制故障、测试开关和坐标追踪不进入普通发行 UI。结构化诊断不含屏幕帧、窗口标题、文稿名、完整路径、配对密钥或逐笔坐标/压力，分享由用户决定。

突然退出后再次启动的本机“上次未正常结束”标记与恢复诊断不是 crash handler，不能区分 fatal error、系统杀进程与用户强制退出。真正 crash 用系统 `.ips` / TestFlight 反馈加对应 dSYM；安装和公证原始日志可能包含路径与账户标识，留在私有材料。[用户取报告步骤](使用者安装指南.md#7-出问题时诊断与退出报告)

## 发布者需要准备的 Apple 资源

截至 2026-10-07 核对，Apple 自 2026-04-28 起要求 App Store Connect 上传使用 Xcode 26 或更新版本及 iOS / iPadOS 26 或更新 SDK；自 2026-09-09 起要求 iOS / iPadOS deployment target 不低于 iOS 13。本机实际 Xcode 27.0（27A266a）、iphoneos SDK 27.0，项目 iPadOS 最低 17，符合这两项现行门槛；这不表示已经通过上传验证或审核。发布时重新核对 [Apple 上传要求](https://developer.apple.com/news/upcoming-requirements/)，发布脚本目前执行 SDK 26+ 的最低门槛预检；Apple 要求变化时同步更新预检。

1. Apple Developer Program 会员团队，具有所需账号角色；确认个人或组织主体并完成协议。免费 Personal Team 不提供公证、TestFlight 或 App Store Connect。[账户区别](https://developer.apple.com/help/account/basics/about-your-developer-account)
2. 选择并登记长期固定的 Mac/iPad bundle ID 与付费 Team ID；iPad 在 App Store Connect 创建记录，签名方式由 sample 配置与本机 Xcode 管理。
3. 本机 Developer ID Application 证书及私钥；iPad Apple Distribution 签名/适用 provisioning。初次创建 Developer ID 需 Account Holder；不要把私钥交给 GitHub Release。
4. 本机 notarytool Keychain profile 的凭据；用 Xcode Organizer / Transporter 或授权账户上传 iPad archive/export，处理加密问卷。
5. 提供真实公开的 support/contact/privacy URL、App Store 元数据、截图、审核说明和 Mac 下载链接；仓库的隐私说明可作为内容，不能用尚不存在的网页占位。

当前脚本与文档不替用户购买会员、生成/吊销证书、创建账号或接受协议，也不会上传 ASC / 发布 GitHub Release。

## 到首次 RC 的最短路径

1. 完成自动检查、无签名 Release 双端 build 和必要的候选预览，检查 version/digest、privacy manifest、图标、诊断与公开清单。无需第二位使用者。
2. 发布者准备上述 Apple 资源，确定正式身份与公开 URL；冻结授权范围内的干净已提交源码、递增 build number，再 `prepare`。签名与实际安装入口验证前，不提前生成 tag 或 Release。
3. `mac` 得到真实 Accepted 且附票据的包；现有 Mac 下载/隔离后的启动、屏幕录制/辅助功能、USB/切换/关键文稿任务验收。
4. `ipad` 后由发布者上传 App Store Connect；先本人 TestFlight 安装，同正式 Mac 配对、完成任务、导出诊断。外部 TestFlight 需要的审查独立处理；将真实安装入口与状态写入发布材料。
5. 同一正式身份的覆盖升级验证：保留一项设置和已有配对再更新；导出两端诊断核对 build/source。初次 identity transition 允许重新授权配对，记录实际结果。
6. 公共资产检查、Release Notes 的实际验收/安装状态更新后创建 GitHub pre-release。可邀请独立用户时再补体验；没有第二用户不使第 1–5 步停止。App Store 正式上架与自动更新留在 RC 之后。

可交付的正式签名候选还需付费团队与正式身份、签名公证和 TestFlight 处理，以及对应包的实际安装、覆盖更新和文稿验收。

### 2026-10-14 正式候选实际渠道状态

0.3.0 build 12：Mac 仅 arm64，原提交已 Accepted 并附公证票据，codesign / stapler / Gatekeeper / dSYM 匹配通过。PadInk App Store Connect 记录已创建，版本草稿 0.3.0，手动发布。Xcode Organizer 已成功上传同一冻结 archive 的 build 12，Apple TestFlight 已列出 0.3.0 (12)，有效期 90 天；处理完成不代表已在 iPad 安装或完成 USB 验收。未提交 App Store / Beta 审核，未公开发布。

实际上传前沿用现有正式团队签名，不重新编译、不自动管理版本/build。重新签名使 ZIP 与签名部分 SHA 改变，去签名后的可执行字节、Info.plist 与原本地导出完全一致，UUID 仍匹配原 dSYM。原导出仅保留为历史打包证据；当前候选清单的 iPad 主资产是实际上传 IPA。源码仍为私有干净提交 e8cd70ff8a146f0f1ee1b41992ed11f0bc2eaf89，App 输入 SHA-256 6d912b4a07671f2be558fcb1a8678232667adf3d97454d54bb47bf7ff7929c4e。现有日用 development build 11、AltStore 路径、配对与文稿没有被替换或删除。

本人内部组“本人 USB 验证”已创建，采用手动分发，已加入且仅加入 build 12。只选择既有账户持有人发起内部邀请；最终发送结果尚未确认，未新增外部测试者，未开启自动分发。本人随后已确认实际使用 TestFlight build12 与公证 arm64 Mac，初步试用未发现问题；该反馈已私有留存。未据此推定全部逐项检查或独立新用户首装通过。
