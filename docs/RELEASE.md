# PadInk 发布候选与分发流程

命令在源码仓库根目录执行。本文描述候选准备、签名、公证、安装验证和发行操作；本地签名覆盖安装与 Developer ID / TestFlight 分发分别核验。正式版为 PadInk，开发版为 PadInk Dev；Mac 安装路径分别为 `/Applications/PadInk.app` 与 `/Applications/PadInk Dev.app`。

## 当前冻结候选与发布者待办

当前源码版本为 **0.3.0 / build 9，准备公开 Beta 2**，本机已安装的 PadInk Dev 仍为 build 8，其 AltStore 安装、启动与手动续签已在 2026-10-12 核对。Beta 2 下载和实际状态以 [发布页](https://github.com/double-u-zw/PadInk/releases/tag/v0.3.0-beta.2)为准；build 9 的完整真人验收尚未完成。已冻结的正式 RC 仍为 `build/rc/0.3.0-rc.1/` 的 RC 1 / build 6；下文 RC 2 命令仅为后续示例。Beta 2 公开当前源码快照、测试与工程工具；匹配 dSYM、签名与恢复材料留在本机，不公开未经检查的本机历史。

冻结源码与验证无签名构建后，安装分发状态仍为待完成。下面事项由发布者准备账户、提供设备并亲自验收；尚未执行的结果填写“未测”。

| 待办 | 完成标准 |
|---|---|
| 当前包的 USB 文稿与稳定性 | 按真人清单 U1–U7 / R1–R4 完成安装、配对、四角定位、写擦滚缩、保存重开、30–60 分钟使用，以及断线、后台、休眠、焦点与权限恢复；记录双端 build/source 和目标应用版本 |
| Wi-Fi 与切换 | 完成 W1–W2；受限网络按 W3 记录实际结果。USB 结果不能代替 Wi-Fi 结果 |
| 应用与设备范围 | 实际使用的应用填写 A1–A5。Intel、最低 macOS 14 / iPadOS 17、第二套设备仍需 E1–E3；未测环境继续注明未验证 |
| 正式团队与 App ID | 准备有效 Apple Developer 团队，确定稳定的 Mac/iPad bundle ID、iPad App Store Connect 记录，填写 ignored 的 `Config/Release.local.xcconfig`。保留原开发签名配置；不提交证书、私钥或凭据 |
| Mac 签名公证 | 准备 Developer ID Application 证书及 Keychain 公证 profile；从冻结源码执行 `mac`，核对 Accepted、staple、签名、Gatekeeper 和两份架构包；通过真实下载首次启动再测试权限、USB 与文稿 |
| iPad TestFlight | 准备 Apple Distribution / App Store profile；执行 `ipad` 后由发布者上传 App Store Connect，等待处理和所需 Beta Review；从 TestFlight 真正安装并与正式 Mac 配对验收 |
| 元数据与审核材料 | 填写支持与隐私入口、App Privacy 与加密合规问卷、截图、审核联系方式、配对步骤和演示；准备审核员可下载的公证 Mac 包。按真实行为填写，不以脚本替代问卷判断 |
| 身份迁移与覆盖升级 | AltStore/个人团队转正式团队单独记录权限、钥匙串与配对变化；首次正式安装后，再对同一正式身份做覆盖更新，核对设置、配对、版本与诊断。不得把首次迁移写成同身份升级通过 |
| 最终分发 | 运行 `check --require-assets --verify-platform`，归档匹配 dSYM/receipt，填写候选说明中的实际验收结果与真实 TestFlight 入口，再上传检查过的公开资产。正式 App Store 上架独立处理 |

真人记录模板见[试用验收清单](试用验收清单.txt)。正式包验收用 Developer ID / TestFlight 的真实安装流程；清单中 AltStore 开发者模式与续签项目不适用时记“不适用”，不能要求 TestFlight 用户按 AltStore 流程安装。

源码冻结后若修复产品代码或改变构建配置，应递增 build 并准备新候选。签名和上传使用当前候选；额外证书/profile 不写入源码，不改变已冻结资产。

## 开发版、正式版与 Mac 芯片包

| 项目 | 开发版 | 正式版产品身份 |
|---|---|---|
| 名称与 Mac 安装目录 | PadInk Dev / PadInk Dev.app | PadInk / PadInk.app |
| 默认使用场景 | 日常源码构建、诊断与内部试验 | 给使用者的 Beta/RC 与后续稳定分发 |
| build variant | development | release |
| bundle ID | 正式基础 ID 后附 `.development` | 当前正式 ID；AltStore 固定 dev.padink.altstore.mac / .ipad |
| 设置与恢复材料 | 独立 bundle domain / 目录 | 保留当前正式版 domain / 目录 |
| 配对 Keychain service | dev.padink03.trust.development | dev.padink03.trust |
| USB loopback / Bonjour | 42372 / _pnk2-dev._tcp | 42371 / _pnk2._tcp |

两版可同时保留，首次 PadInk Dev 需要独立授权与配对，不拷贝已有版的密钥或设置。双端须选择同一版；芯片包共用该版身份。`release` 指产品身份，`rc` / `development` / 后续 `release` 指成熟度渠道，`altstore` / `direct` / `testflight` 指安装分发方式。给使用者的 RC 不会因为产品身份叫正式版就变成稳定版。

Mac 分别构建 arm64 与 x86_64 的单架构 App；文件名带架构，包内二进制与匹配 dSYM 必须核对。AltStore 本地包每版输出两个 DMG、两个含对应 DMG 和共用 iPad IPA 的 ZIP；Developer ID 路径对每个架构分别 archive、签名、公证、附票据并生成 ZIP，只有两份都通过才允许完整公开 staging。正式签名工具只使用正式版身份。

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

## 本轮公开测试版（0.3.0 Beta 2 / build 9）

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
- TLS、ECDH/HKDF/HMAC 都涉及加密。发布者在 App Store Connect 回答 export compliance 问卷，确认地区和是否需要文件；脚本不会猜测 `ITSAppUsesNonExemptEncryption = NO`，不能因为用了 CryptoKit 就跳过判断。[Apple 加密申报](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)

## 版本、源码与兼容约定

`Config/Version.xcconfig` 是双端版本的唯一来源：当前配置为 `MARKETING_VERSION = 0.3.0`、`CURRENT_PROJECT_VERSION = 9`、源码开发默认渠道 `development`，候选脚本构建时明确覆盖为 `rc`。正式 Apple 版本字段不带 `-rc`；发布标题可使用 `0.3.0 RC 2`，维护者批准后 Git tag 可使用 `v0.3.0-rc.2`，发布 tag 在实际发布时创建。

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
python3 engineering/scripts/rc-release.py mac --release build/rc/0.3.0-rc.2 --arch all
# 也可分别执行 --arch arm64 与 --arch x86_64；两份都完成才允许公开 staging
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

正式 Mac 包分别构建 arm64 / x86_64 单架构二进制，Intel Mac 仍尚未真机验收；两端 archive 保留与二进制 UUID 匹配的 dSYM。正式候选源码包绑定干净的提交，不含未提交 diff、签名配置、配对密钥或验收文件；working-tree preview 源码包显式包含当前源码改动，仅用于预览。Xcode archive / dSYM 要与实际发行二进制 UUID 匹配，保留期限至少覆盖此版本的支持期；缺失或不匹配就无法可靠还原 crash stack。[Apple crash 诊断](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs)

## 升级、身份和数据保留

PadInk 不保存文稿；文稿在 Mac 目标应用里。PadInk 的偏好在本 App UserDefaults，设备身份/信任在本机 Keychain，诊断由使用者主动导出。正常升级不删除这些数据，不重置配对。

保留数据的发布条件：固定 team、bundle ID、Keychain 访问权限/代码签名要求、服务与 account 名，存储格式兼容，覆盖安装。**从 Apple Development 改为 Developer ID 即使同 team / bundle ID，Mac Keychain ACL 与 TCC 授权仍须实际检查，不能仅凭代码宣称无缝。** 免费测试者的个人团队与正式团队/bundle通常不同，首次进入正式包重新授权、配对，不自动导出或搬运信任私钥。

升级前保存文稿、退出 Mac App；覆盖 Mac 包、更新 iPad。优先发布两端一起更新的组合。首次 RC 不承诺跨版本降级，不引入会破坏旧读者的存储迁移；若以后更改存储格式，必须先定义向后兼容和回退边界。Mac 可由维护者指定已公证旧包，iPad 只在 TestFlight 构建仍有效时选旧构建；App Store 不是任意旧版包仓库。

## Release 日志、诊断与 crash

Release 用户入口保留连接状态、权限、配对、版本与主动导出诊断。构建细节便于支持，不需要开发者测试入口；逐笔回放、强制故障、测试开关和坐标追踪不进入普通发行 UI。结构化诊断不含屏幕帧、窗口标题、文稿名、完整路径、配对密钥或逐笔坐标/压力，分享由用户决定。

突然退出后再次启动的本机“上次未正常结束”标记与恢复诊断不是 crash handler，不能区分 fatal error、系统杀进程与用户强制退出。真正 crash 用系统 `.ips` / TestFlight 反馈加对应 dSYM；安装和公证原始日志可能包含路径与账户标识，留在私有材料。[用户取报告步骤](使用者安装指南.md#7-出问题时诊断与退出报告)

## 发布者需要准备的 Apple 资源

截至 2026-10-07 核对，Apple 自 2026-04-28 起要求 App Store Connect 上传使用 Xcode 26 或更新版本及 iOS / iPadOS 26 或更新 SDK；自 2026-09-09 起要求 iOS / iPadOS deployment target 不低于 iOS 13。本机实际 Xcode 27.0（27A266a）、iphoneos SDK 27.0，项目 iPadOS 最低 17，符合这两项现行门槛；这不表示已经通过上传验证或审核。发布时重新核对 [Apple 上传要求](https://developer.apple.com/news/upcoming-requirements/)，不将日期或 SDK 规则硬编码进发布脚本。

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
