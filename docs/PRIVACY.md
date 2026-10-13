# PadInk 隐私说明

更新日期：2026-10-12。本文描述当前 PadInk 代码的行为。政策地址为 https://github.com/double-u-zw/PadInk/blob/main/docs/PRIVACY.md，反馈地址为 https://github.com/double-u-zw/PadInk/issues。正式发行采用 iPad App Store 与 Mac GitHub Release；TestFlight 用于发行前测试，正式签名与安装验证尚待完成。

## 数据如何使用

PadInk 读取 Mac 主屏画面，直接传给你确认配对的 iPad；iPad 的 Pencil / Touch 输入直接传回 Mac，作用于当前应用。画面和输入用于实时操作，不由 PadInk 保存为文稿，也不上传 PadInk 云服务。目标应用自己的文稿、保存行为与隐私政策由该应用负责。

USB 与 Wi-Fi 都先验证配对信任。USB 通过系统 USB 通道传输，PadInk 未在 USB 帧层额外加密；Wi-Fi 使用系统 TLS PSK 加密。首次配对需要两端确认，Wi-Fi 配对核对六位短码。不要确认陌生设备；设置中可忘记设备撤销后续连接信任。

## 本机保存的内容

- 本 App 偏好，例如手指输入开关与首次使用引导状态。
- Keychain 中的设备身份密钥和已确认设备的信任记录。iPad 使用仅限本设备的 Keychain 项；不会通过 iCloud Keychain 同步配对密钥。
- 有限的本机诊断与运行/上次未正常结束信息，用于连接恢复和由你主动导出的故障排查。

正式 iPad App 由 App Store 安装，测试发行由 TestFlight 安装；PadInk 本身不索取、保存或代理 Apple 账号凭据。历史个人测试版曾通过 AltServer / AltStore 安装，其账号与签名由该工具处理。

当前没有广告 SDK、第三方分析 SDK、PadInk 用户账户、自动上传日志或后台上传 crash 的服务。Apple 的 TestFlight / 系统分析服务按 Apple 的规则处理反馈与 crash，和 PadInk 本机诊断导出不同。

## 诊断与求助

Release 诊断包含 App 版本/build/渠道、源码 revision/digest、系统与设备型号、设备标识摘要、连接/权限/视频/input 队列状态与有限故障记录；不含屏幕帧、窗口标题、文稿名、完整文件路径、配对私钥或逐笔坐标/压力。异常退出后的有限恢复信息不是完整系统 crash 报告。

诊断先在本机生成，由你决定是否分享给维护者。主动分享的诊断、反馈或系统 `.ips` 只应用于处理这次问题；本轮通过 GitHub Issues 接收反馈：Issues 为公开内容，不提交个人文稿、密码、证书或私钥；诊断分享由使用者决定。维护者不自动下载或长期归档反馈附件；问题排查结束后可联系维护者删除其保留的诊断副本，GitHub 上的公开记录按平台规则由提交者和仓库维护者处理。系统 crash、安装/签名/公证日志可能包含比应用诊断更多的设备、路径或签名账户信息，发送前可查看，不发送证书、私钥、钥匙串或 `*.local.xcconfig`。

## 保存期限与删除

画面与输入只在当前会话中处理，不做内容存档；连接队列随会话结束释放。偏好与配对保留到你重设、忘记设备或相关系统存储被移除。恢复诊断仅保留当前运行及至多一次先前未正常结束的记录（文件上限 512 KB），在本机随运行覆盖更新；主动导出的文件保留到你自行删除。没有由维护者持有的用户账号数据库。主动发送给维护者的反馈按上述求助说明处理。

## 控制与权限

在 PadInk 设置中关闭手指输入或忘记配对；在系统设置撤销屏幕录制、辅助功能、本地网络或自动化授权；退出两端 App 停止当前传输。删除 App 不一定清除系统 Keychain 的所有旧项，删除 App 不是正常续期、升级或撤销信任的方法；撤销可信设备先用“忘记设备”。导出的诊断可在 Finder / 文件 App 中自行删除。

[安装与诊断步骤](使用者安装指南.md) · [Apple TestFlight 数据说明](https://testflight.apple.com/)

## English

Updated October 12, 2026. PadInk mirrors your Mac's main display to the iPad you approve and sends Pencil/touch input back to the Mac. Frames and input are processed in real time, not saved as documents or sent to a PadInk cloud service. The target Mac application is responsible for document storage and its own privacy practices. USB authenticates paired devices but does not add encryption to application frames; Wi-Fi uses system TLS PSK. Only pair devices you recognize.

PadInk stores app preferences, device identity keys and approved pairing records in local system storage/Keychain. iPad pairing keys are device-only and do not sync through iCloud Keychain. Limited local diagnostics and recovery information include version/build/channel, source identity, system/device model, device-identifier summaries and connection/permission/video/input-queue status. They exclude screen frames, document names, window titles, full file paths, pairing private keys and per-stroke coordinates/pressure. Recovery storage retains the current run and at most one preceding unfinished run, with a 512 KB file limit; exported files remain until you delete them. Session queues are released when the session ends. Preferences and pairing remain until reset, forgotten or removed by the relevant system storage operation.

There are no PadInk accounts, ads, third-party analytics SDKs, automatic diagnostic uploads or PadInk crash-upload service. PadInk does not request, store or proxy Apple account credentials. The planned official iPad distribution is App Store, with TestFlight for testing; formal signing and installation validation are still pending. Older personal test builds used AltStore/AltServer, which handle their own signing/accounts. Apple's TestFlight and system analytics follow Apple's policies.

You choose whether to export/share diagnostics. Public support and privacy-request contact is [GitHub Issues](https://github.com/double-u-zw/PadInk/issues); reading needs no login, posting requires a GitHub account. Issues are public. Do not submit private documents, passwords, certificates, keys or local signing configuration. Voluntarily shared diagnostics/feedback are used to resolve the reported issue. The maintainer does not automatically download or permanently archive attachments; after resolution you may request deletion of retained diagnostic copies. GitHub records are handled by the author/maintainer under GitHub's platform rules. System crash reports and signing logs may expose additional device/path/account information: inspect them before sharing. A private support contact is pending confirmation before formal release.

Disable finger input or forget a trusted device in PadInk settings. Revoke Screen Recording, Accessibility, Local Network or Automation permission in system settings; quit both apps to stop transmission. Forget devices before removing trust; uninstalling may leave Keychain entries and is not the normal upgrade/re-pair procedure. Delete exported diagnostics in Finder or Files. There is no developer-held PadInk account database. [Installation](使用者安装指南.md) · [Apple TestFlight](https://testflight.apple.com/).
