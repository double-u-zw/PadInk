# PadInk 架构

本文描述当前实现。协议和支持边界分别见 [PROTOCOL](PROTOCOL.md) 与 [SUPPORT_MATRIX](SUPPORT_MATRIX.md)。

## 1. 模块与依赖

```text
PadInkCore <- PadInkTransport <- PadInkMacKit / PadInkPadKit <- Xcode App hosts
     ^                            ^
     +--------- ReplayKit / padink-replay（本机工具）
```

| 目录 | 职责 |
|---|---|
| `Sources/PadInkCore` | PNK2 帧与 payload、身份与认证、会话和存活策略、输入语义与新鲜度、几何、视频队列与诊断 |
| `Sources/PadInkTransport` | USB / Wi-Fi 字节流、发现、安全承载、附着、心跳与视频连接替换 |
| `Apps/Mac` | Mac 协调器、屏幕捕获编码、Pencil / Touch 投递、应用公开缩放、菜单和主窗口 |
| `Apps/iPad` | iPad 协调器、UIKit 捕获、解码与 Metal 呈现、设置与状态 UI |
| `Hosts` | 两端 App 入口、生命周期和发行资源 |
| `Tests` / `Fixtures` | Core、Transport、App、Replay 回归；实际样本和持久化 fixture |
| `Tools` | 真实应用回放与 InkML / 放置位置比对，不进入 App |
| `scripts` / `Config` | 确定性工程生成、测试、签名设置、版本、源码身份和发行材料 |

SwiftPM app kits 承载产品逻辑，以便 macOS 上运行回归；iPad 的 UIKit 部分按平台编译。Xcode targets 只链接 app kit 并提供 host 与资源。工程下限是 macOS 14 / iPadOS 17，实际验证环境另见支持矩阵。

## 2. 会话、传输与信任

`LogicalSession` 管理会话元数据、恢复 token、世代和暂停/恢复；具体流归 `Attachment`。每次附着有新的 UUID 与 generation，恢复不续传输入或旧视频帧。每条流只有一个 `ByteStream` 边界；同一 PNK2 协议用于 USB 和 Wi-Fi。

| 流 | 作用 | 生命周期 |
|---|---|---|
| A：Control + Input | 握手、状态、心跳、Pencil / Touch 与几何 | A 失败结束附着，释放输入并恢复 |
| B：Video | H.264 config / access unit、反馈与请求 IDR | 拥塞降级；失败只替换 B，保留 A 身份 |

Mac 使用 usbmuxd ListDevices / Connect，经本机服务访问 iPad loopback（正式版 42371，开发版 42372）。usbmuxd 是产品路径唯一未公开为 App 契约的系统接口，封装在 USB 层。原始隧道建立只表示 dial 阶段成功；UI 的 active 需要认证、附着和首个实际画面。

iPad USB listener 由独立网络队列和 epoch 管理。前后台、start/stop、失败与 retry 都检查 epoch；终止失败以 0.5 s 起、上限 10 s 退避。旧 listener、accept 和 retry 回调不能建立新 epoch 的流。

Wi-Fi 使用 Network.framework / Bonjour（正式版 `_pnk2._tcp`，开发版 `_pnk2-dev._tcp`），关闭 peer-to-peer 发现。已配对产品流先建立 TLS 1.2 PSK，再执行每对设备的挑战认证；首次无线配对使用独立、有时限的六位 SAS 确认入口。身份和 trust 事务式写入本机 Keychain，失败保持离线；无匿名回退，不同步云端，不从历史版本复制私钥。

`TransportSelection` 对同一可信设备优先 USB；Wi-Fi 在线发现 USB 时，空闲立即切换，有输入时最多等 500 ms 后安全结束再切换。Wi-Fi 不抢占已在线 USB；拔线后重新附着。所有切换都要求重新落笔，断线输入不补送。

## 3. 输入身份、队列与几何

`InputContext` 是 attachment UUID + generation 的不可变快照，在 UIKit 捕获线程冻结后进入输入队列。捕获、发包、Mac 接收、目标探测、执行、完成与定时回调均检查这个身份。关闭或替换只结束匹配旧身份的工作；B 重建保留 A 的 InputContext。

iPad 的有界捕获 mailbox 和 `PadInputLink` 保留健康路径的 actual / coalesced / terminal 顺序。当前发送策略为 100 ms 最大本地排队年龄、64 KiB / 256 帧队列和 250 ms 在途写停滞期限。过载或过期安全取消整笔，不能跳过样本后接着发送。优先取消只针对对端已知的活动手势；写无法完成则关闭 A，让对端确定性释放。

Mac 在网络接收入口记录本地 stamp，在投递前判断 100 ms 样本年龄和 1 s 手势截止；keepalive 每 200 ms 只证明手势还活着，不刷新旧样本年龄。截止到点即过期，迟到样本或 keepalive 不能复活手势。跨设备时钟估计只进诊断。

`VideoGeometry` 在视频 aspect-fit 矩形、归一化输入和 Mac 全局逻辑坐标之间统一映射：letterbox 起笔忽略，活动笔越界夹紧，不乘 Retina scale，支持负显示原点。`PencilGeometryState` 管理几何世代和 ready。尺寸/方向变化先取消当前输入；只有精确匹配的实际 Metal present 才使几何可用并发送 PRESENTED_GEOMETRY。

Pencil 采集拷贝 actual 与 coalesced、排序去重并保留静止终点，不发送 predicted。Mac `PencilInputPipeline` 通过 `PencilInjectionBackend` 使用 `.hidSystemState` 与 HID event tap，包含 tablet 字段、proximity 和幂等释放。样本间隔保留；不依赖跨设备时钟决定投递。

Touch 在 iPad 状态机中判定 Pointer / Scroll / Magnify，再发送语义。Pencil / hover 优先；第三指、系统取消、触点替换会取消，全部抬起后重新开始。正常双指先后抬起只发一次 ended，剩余触点不得变成点击或拖动。Mac 普通 scroll 保留小数像素累积、固定 began 落点，并明确清除继承的 Command 修饰键。

## 4. 应用公开缩放与执行边界

`ApplicationZoom` 从公开 API / AX 能力选择适配器。PowerPoint 优先稳定窗口 ID 的公开 AppleScript 视图缩放并读回；必要时使用唯一公开 AX slider。Safari、Chrome、Preview 使用可唯一识别的公开菜单/能力；不靠本地化菜单标题、固定索引、版本白名单或键盘注入兜底。

`ZoomActionContext` 冻结 InputContext、手势、几何、目标 revision、目标快照与 action UUID。`ZoomPermit` 将取消与调用前 claim 同步；检查身份、目标和新鲜度后才执行公开动作。锁内只做短状态判断，外部 AX / AppleScript / CGEvent 调用在锁外运行。取消后不能 claim 新调用；已 claim 的一次调用可以完成，不承诺与系统前台切换原子化。

`ZoomController` 同时最多一个物理 worker 和一个当前 action。取消使旧 permit 无效，但 worker 占位保留到该任务完成；旧结果不能应用于新 action，新 action 只在旧任务退休后继续。这覆盖 probe、执行、等待和 completion 的跨队列竞态。

GoodNotes 使用公开 Command + continuous pixel wheel，要求唯一且激活的 `document_content_area` 与匹配 AX window / focus；编辑、菜单、弹窗、窗口变化和歧义目标拒绝缩放。当前连续参数为约 60 Hz、100 ms 新鲜度、每 log unit 160 像素、最多 64 像素待执行；亚像素保留，确认反向达到 1 像素替换旧 permit。ended / cancelled 立即清空需求，无惯性尾流。普通滚动不带 Command，缩放明确带 Command，不使用私有 magnify。

其他公开适配器使用 `DiscreteZoom`：log(1.12) 一档、最多两档需求、180 ms 提交间隔，仅等待尚未经过的部分；小幅反向抵消净移动，持续半档反向丢弃旧方向整档。正常 ended 可完成有限已收到需求，真正 cancelled 清空。

## 5. 故障分级

行号用于协议 ERROR 和诊断，相关测试以 `testFaultRow…` 保留这些编号。

| 行 | 异常 | 动作 | 原因码 |
|---|---|---|---|
| 1 | 视频队列拥塞，或 B 心跳被视频延迟 | 编码前跳帧、降低码率 / FPS，必要时丢整个 GOP 并请求 IDR；保留输入与附着 | 无 cancel |
| 2 | 接收至投递排队超过 100 ms | 安全结束整笔/手势，拒绝后续样本 | 4 staleSample |
| 3 | 时钟估计不确定度高 | 降低诊断精度，不门控输入或视频 | — |
| 4 | 输入几何世代不匹配 | 拒绝当前手势，会话保持 | 3 geometryMismatch |
| 5 | 目标消失或前台应用切换 | 释放接触/proximity，取消匹配输入与缩放 | 5 targetChanged |
| 6 | 手势 1 s 截止到期 | 释放手势；迟到消息不可复活 | 2 gestureTimeout |
| 7 | A 报错或静默超过 3 s | 结束附着、取消所有匹配输入并重连 | 1 transportLost |
| 7b | B 失败或停滞超过 10 s，A 正常 | 只认证并替换 B，从新 IDR 开始 | 无 cancel |
| 8 | 认证失败或协议违规 | 失败连接/附着，安全释放关联输入 | 10 protocolViolation |

B 队列超过 1 MiB 或 250 ms 未排空进展为拥塞，不能按心跳 RTT 判断 B 死亡。视频活动不能保持 A 存活；A 活动不能掩盖 B 停滞。

## 6. 视频边界与恢复

Mac 使用 ScreenCaptureKit → VideoToolbox H.264，iPad 使用 VideoToolbox → Metal。USB profile 以 60 fps 和高质量码率为起点；Wi-Fi 初始码率为 USB 的 35%。持续拥塞 1 s 降为 50% 码率，3 s 降为 30 fps，健康 10 s 恢复。当前不做分辨率自适应；光栅在连接/显示协商时确定。

Mac 编码前按发送占位跳帧；`VideoSender` 保留连续 GOP、最新 IDR 与有界待发送工作。丢参考链后从新 IDR 开始，不把残缺 P 帧送给解码器。

iPad `VideoDecodePump` 在跨媒体队列前限制待解码压缩帧：2 帧、8 MiB、250 ms，config 有独立单槽。过载、过期或缺口丢整个待解码参考链并请求 IDR；同时最多一个物理 drain，旧 consumer 只在自己的在途工作完成后 reset，锁内不运行客户回调。

`VideoDecodeContext` 包含 InputContext 和独立视频 epoch。B 替换退休旧 decoder 与 present 回调，但保留 A 的输入身份；旧 B 已提交 drawable 的迟到完成不能开放新 epoch。Metal 最新帧优先且限制在途，首帧必须实际 present 才建立 ready。

## 7. UI、诊断与发行

Mac 主窗口、菜单栏和 iPad 状态读取既有 model。`ConnectionPhase` 区分等待、连接中、等待画面、可用、恢复、暂停、需要处理；传输建立不等同可用。iPad 镜像之外的控制栏保留操作区域，设置关闭后继续既有捕获与几何路径。Mac 关闭主窗口保留菜单栏，重新打开时显示窗口。

Release 保留有限状态、权限、配对、版本/源码身份和主动导出诊断，剥离逐笔坐标/压力、窗口标题、文稿名、完整路径和画面。Debug 回放可产生显式授权的临时截图和测试文稿，仅不可替代原始样本需要保留。上次未正常结束的恢复标记不是 crash handler；真实 crash 使用系统 .ips / TestFlight 反馈与匹配 UUID 的 dSYM。

版本与默认渠道来自 `Config/Version.xcconfig`，本机签名配置 ignored。源码 identity 由产品源码/配置摘要与 Git commit 绑定；RC prepare 冻结材料，发行签名、公证和 TestFlight 是独立步骤。正式版名为 PadInk，开发版名为 PadInk Dev；两版 bundle ID / UserDefaults、恢复目录、Keychain service、USB 端口与 Bonjour 类型独立，避免开发运行影响原安装。正式版保留既有持久身份，芯片包不区分存储/配对。包内 `PadInkBuildVariant` 决定版本身份，缺失时按原正式版处理；成熟度 channel 与安装 distribution 独立。开发、验收和发行命令见 [开发者指南](开发者指南.md) 与 [RELEASE](RELEASE.md)。
