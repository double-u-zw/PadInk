# PNK2（PINK/2）当前协议

当前 wireVersion 为 **3**；协议与 App Version / Build 独立。本文与 `Sources/PadInkCore/Protocol/`、身份/会话实现以及 payload golden 测试对应。历史协议实现可从 Git 恢复。0.1 的 PINK v3 和 0.2 的 v6 不兼容，不提供旧协议模式。

开发版与正式版使用独立连接发现与配对命名空间，双端须使用同一版；帧、payload 和 wire version 仍相同，芯片差异不改变协议。

## 1. 连接与逻辑通道

一次传输附着（transport attachment）由两条独立的有序字节流组成：

| 连接 | ConnectionKind | 承载的逻辑通道 | 理由 |
|---|---|---|---|
| A | `controlInput` = 1 | Control + Input | 控制与输入都很小，必须低延迟；与视频分离 |
| B | `video` = 2 | Video（以及本连接自己的 HELLO/心跳/ERROR/GOODBYE） | 大视频帧不阻塞 Pencil down/up（输入和视频互不排队） |

- USB：两条 TCP 连接都经 usbmuxd 连到 iPad loopback **同一个端口**（正式版 42371，开发版 42372）；每条连接的第一个帧是 HELLO，声明 ConnectionKind。
- Wi-Fi：Bonjour（正式版 `_pnk2._tcp`，开发版 `_pnk2-dev._tcp`）一个服务、一个端口，同样以 HELLO 区分两条连接。
- iPad 始终是监听方，Mac 是发起方。
- 两条连接都有自己的心跳，但**两条连接的存活判定规则不同**（§1.1）。只有 A 死亡会结束整个附着并取消输入；B 拥塞只降级，B 失败或长时间停滞只重建 B。

### 1.1 存活判定：视频拥塞 ≠ 链路死亡

B 是一个有序字节流：Mac 发出的 HEARTBEAT 会排在已入队的大视频帧之后，即使计时器在网络队列上，iPad 也可能几秒后才收到。因此**任何一端都不用心跳往返时间判断 B 的死活**，RTT 只在 A 上测量。

| 连接 | 判定 | 结论 | 对输入的影响 |
|---|---|---|---|
| A | 传输报错，或 `controlSilenceLimit`（初值 3 s）内没有收到任何字节。A 只有小消息，两端每 1 s 发心跳 | 附着死亡（故障表第 7 行） | `cancelAll(transportLost)`，进入重连 |
| B | 发送队列超过 `congestedQueueBytes`（初值 1 MiB），或队列非空且 `congestionDrainDelay`（初值 250 ms）内没有排空进展 | 视频拥塞（第 1 行） | 无。编码前跳帧、降码率 |
| B | 传输报错；或队列非空且 `videoStallLimit`（初值 10 s）内无排空进展；或 `videoStallLimit` 内没有收到 iPad 的任何字节 | 只重建 B（第 7b 行） | 无。Pencil 手势继续 |

- iPad→Mac 方向的 B 只承载小消息（HEARTBEAT、KEYFRAME_REQUEST、VIDEO_FEEDBACK），不会被视频帧阻塞，所以“收到 iPad 的字节”是可靠的 B 存活信号。
- 视频活动永远不能让 A 保持存活；A 的活动也不能掩盖 B 的停滞。
- iPad 不主动断开 B：B 停滞时只显示“画面暂停”，由 Mac 发起重建。
- 本节记录当前实现默认值；改变策略须同步代码、协议说明与回归。

## 2. 帧信封（36 B，冻结）

所有整数大端；浮点为 IEEE-754 binary32 的大端位模式。头部 36 字节：

| 偏移 | 长度 | 字段 | 规则 |
|---:|---:|---|---|
| 0 | 4 | magic | `0x504E4B32`（"PNK2"）。收到旧 magic `0x50494E4B`（"PINK"）→ `legacyPeer`，UI 提示对端是旧版 PadInk |
| 4 | 2 | wireVersion | 当前 3。协议版本与 App 版本无关，只在线格式变化时升级 |
| 6 | 2 | messageType | §3 |
| 8 | 2 | flags | bit0 `CRITICAL`：接收方必须理解；bit1 `KEYFRAME`：仅 VIDEO_FRAME。其余位必须为 0 |
| 10 | 2 | reserved | 必须为 0 |
| 12 | 4 | generation | 逻辑会话世代。HELLO/HELLO_ACK 之前为 0；之后每帧必须等于当前世代，旧世代产品帧视为协议违规 |
| 16 | 8 | sequence | 每条连接每个方向独立，从 1 开始，严格 +1。缺口或重复 = 协议违规 |
| 24 | 8 | timestamp | 发送方单调时钟纳秒。**只用于诊断与延迟测量**，从不用于输入新鲜度判断 |
| 32 | 4 | payloadLength | 不超过该类型上限（§3）；头部全部校验通过后才缓冲 payload |

解码器每条连接最多持有一个头部加一个有界 payload；不做字节扫描或重同步，任何错误都使该连接失败。

**版本不匹配**：HELLO 的头部和 payload 前缀永久冻结。解码器对非 3 版本只放行 HELLO（携带对端 wireVersion），握手层据此回复 ERROR `versionMismatch`，并用对端 HELLO 中的 App 版本告诉用户应更新哪一端。其他类型遇到非 3 版本 → 协议违规。

## 3. 消息类型（单一来源 `MessageRegistry`）

下表由 `FrameTests.testProtocolDocumentMatchesRegistry` 与代码逐行比对。`required` = 发送时置 CRITICAL；`optional` = 旧接收方可以忽略。上限单位为字节。

| 类型 | 名称 | 连接 | 必需性 | 上限 | 方向与含义 |
|---|---|---|---|---|---|
| 0x0001 | HELLO | A, B | required | 1024 | Mac→iPad：发起附着 |
| 0x0002 | HELLO_ACK | A, B | required | 1024 | iPad→Mac：接受附着，确认世代 |
| 0x0003 | AUTH_PROOF | A, B | required | 256 | 双向：每对密钥认证 |
| 0x0004 | AUTH_RESULT | A, B | required | 64 | 双向：认证结果 |
| 0x0010 | HEARTBEAT | A, B | required | 16 | 双向：链路存活 |
| 0x0011 | HEARTBEAT_ACK | A, B | required | 32 | 双向：RTT 测量 |
| 0x0020 | GOODBYE | A, B | required | 8 | 双向：有意断开及原因 |
| 0x0021 | ERROR | A, B | required | 512 | 双向：错误码（§6） |
| 0x0030 | PRESENTED_GEOMETRY | A | required | 64 | iPad→Mac：已呈现几何世代与 ready |
| 0x0031 | INPUT_SETTINGS | A | required | 16 | iPad→Mac：Touch 开关、仅 Pencil |
| 0x0032 | STATUS | A | optional | 1024 | Mac→iPad：当前输入所有者、应用策略、最近取消原因 |
| 0x0050 | DIAGNOSTIC_REQUEST | A | optional | 16 | 双向 |
| 0x0051 | DIAGNOSTIC_REPLY | A | optional | 32768 | 双向：有界 JSON 摘要 |
| 0x0101 | PENCIL | A | required | 9236 | iPad→Mac：一个手势的 1–256 个实际样本 |
| 0x0102 | POINTER | A | required | 64 | iPad→Mac：一指 tap/drag 语义事件 |
| 0x0103 | SCROLL | A | required | 64 | iPad→Mac：双指滚动 |
| 0x0104 | MAGNIFY | A | required | 64 | iPad→Mac：捏合（分档或连续意图） |
| 0x0105 | INPUT_CANCEL | A | required | 32 | iPad→Mac：显式取消某手势 |
| 0x0106 | GESTURE_KEEPALIVE | A | required | 32 | iPad→Mac：活跃手势仍存在 |
| 0x0110 | INPUT_REJECTED | A | required | 32 | Mac→iPad：某手势被拒绝/结束及原因 |
| 0x0201 | VIDEO_CONFIG | B | required | 65536 | Mac→iPad：SPS/PPS、尺寸、视频世代 |
| 0x0202 | VIDEO_FRAME | B | required | 8388608 | Mac→iPad：AVCC access unit |
| 0x0203 | KEYFRAME_REQUEST | B | required | 8 | iPad→Mac |
| 0x0204 | VIDEO_FEEDBACK | B | optional | 64 | iPad→Mac：实际硬件解码输出确认（extendedVideo） |
| 0x0205 | VIDEO_PROFILE | B | optional | 64 | Mac→iPad：当前 profile 与码率（展示/诊断用） |

**未知消息**：已知类型出现在错误连接 → 违规。未知类型带 CRITICAL → 违规（`unknownCritical`）。未知类型不带 CRITICAL → 丢弃 payload（上限 16 KiB），计入诊断 `ignoredUnknown`，连接继续。

**能力（capabilities）**：HELLO / HELLO_ACK 声明 `pencilHover`、`pencilPressure`、`pencilTilt`；bit3 `extendedVideo` 表示理解扩展视频 payload，不保证任何具体硬件配置可用。应用缩放在 Mac 端实时探测菜单或公开接口，不在握手宣称应用兼容。必需功能不用能力位表达——由 wireVersion 保证。

## 4. Payload

### 4.1 HELLO / HELLO_ACK（`ControlPayloads.swift`）

两者同一布局，所有字段总是存在（不再有“仅 ACK”字段，解析更简单）。前 8 字节**永久冻结**。

| 字段 | 类型 | 说明 |
|---|---|---|
| minWireVersion, maxWireVersion | u16, u16 | **冻结**。`VersionNegotiation` 取交集最大值；无交集时给出“更新本机”或“更新对端” |
| connectionKind | u8 | **冻结**。1 / 2 |
| role | u8 | **冻结**。1 = Mac，2 = iPad |
| reserved | u16 | **冻结**。0 |
| appVersion | u8 长度 + UTF-8 ≤ 32 | 按合法 UTF-8 边界截断；版本不匹配时用于中文提示 |
| deviceID | 32 字节 | 身份公钥（Curve25519）的 SHA-256 |
| attachmentID | 16 字节 | Mac 为每次附着生成；两条连接必须相同 |
| resumeToken | 32 字节 | 全 0 = 新逻辑会话；否则请求恢复（§5） |
| generation | u32 | HELLO：Mac 提出的会话世代；ACK：iPad 确认的世代 |
| capabilities | u32 位图 | bit0 pencilHover、bit1 pencilPressure、bit2 pencilTilt（iPad）、bit3 extendedVideo（双端） |
| signingExpiry | u64 Unix 秒 | iPad 的描述文件到期时间；0 = 未知或 Mac。用于到期前 3 天提醒 |
| displayName | u8 长度 + UTF-8 ≤ 64 | 只在 UI 显示，不进诊断导出 |
| drawableWidth, drawableHeight | u32, u32 | iPad 在 B 连接上给出视频光栅协商用的像素尺寸；其他情况为 0；≤ 8192 |

### 4.2 HEARTBEAT / HEARTBEAT_ACK

HEARTBEAT：`nonce u64`（8 B）。ACK：`nonce u64, receiveTime u64, sendTime u64`（24 B）（对端单调时钟，NTP 式偏移估计只进诊断）。两端在 A 与 B 上每 1 s 各发一次（B 上 Mac 侧可在有视频帧在途时省略）。RTT 与时钟偏移**只用 A 上的 ACK 计算**；B 上的 ACK 只作为“收到对端字节”的信号，其延迟不参与任何判定（§1.1）。

### 4.3 PENCIL

```
gestureID u64          // iPad 单调递增，跨会话不复用
geometryGeneration u32 // 本手势开始时已呈现的几何世代；整个手势不变
batchFlags u8          // bit0 首样本为 began，bit1 末样本为 ended/cancelled；由样本推导，不一致即拒绝
reserved u8, reserved u16
count u16              // 1–256
reserved u16
                       // 批次头合计 20 B：8 + 4 + 1 + 1 + 2 + 2 + 2
count × sample (36 B): // 4 + 8 + 5×4 + 1 + 1 + 2
  sampleSeq u32        // 手势内从 1 开始，跨批次严格 +1
  timestamp u64        // UIKit 时间戳 ns（诊断用）
  x f32, y f32         // 已呈现视频矩形内的归一化坐标 [0,1]
  pressure f32         // force / maximumPossibleForce；不可用时为 0，并在 capability 中声明不可用
  altitude f32, azimuth f32
  phase u8             // 1 began, 2 changed, 3 ended, 4 cancelled
  flags u8             // bit0 estimated；其余位必须为 0
  reserved u16
```

payload 长度必须恰好等于 `20 + count × 36`，上限 `20 + 256 × 36 = 9236` 字节（与 §3 表一致，由 `PencilBatch.maxPayload` 单一定义）。所有保留字段必须为 0。began 只能是第一个样本且 sampleSeq = 1；ended/cancelled 只能是最后一个样本；时间戳不递减；坐标、压力、角度必须有限且在范围内。整批校验通过前不交付任何样本。

语义沿用 Baseline 已验证规则：actual + coalesced 全部保留且有序；终点样本即使静止也保留；不发送预测点；开始于 letterbox 的笔触被忽略，进行中越界的点夹紧。

### 4.4 POINTER / SCROLL / MAGNIFY

三种 Touch 消息均固定 44 字节（`TouchEvent`）：

```text
gestureID u64          // 最高位 1，与 Pencil 隔离
sequence u32           // began 为 1；其后严格递增
timestamp u64          // 诊断用
geometryGeneration u32 // 整次手势不变
kind u8                // 1 pointer / 2 scroll / 3 magnify
phase u8               // 1 began / 2 changed / 3 ended / 4 cancelled
clickCount u8          // 1 或 2
reserved u8            // 0
x f32, y f32, dx f32, dy f32
```

帧 type 与 kind 必须匹配；浮点必须有限，x/y 在 [0,1]，dx/dy 在 [-1,1]。Pointer 的 delta 为零；Magnify 的 dx 为相邻 scale ratio 的自然对数、dy 为零。Scroll 的 delta 为视频矩形归一化位移，Mac 统一换算逻辑显示尺寸与 Quartz 方向。禁止在手势中换 kind / 几何世代，手势 ID 不跨附着复用。

INPUT_SETTINGS 为 1 字节：0 仅 Pencil，1 允许 Touch。切换为 0 先结束活动 Touch；Pencil begin 无条件释放 Touch，Touch 不能抢占 Pencil。Touch 同样使用 100 ms 本地样本年龄、1 s 手势截止和 200 ms keepalive。

iPad 当前判定参数：80 ms 确认窗口、drag 6 pt、tap ≤400 ms、双击间隔 ≤300 ms 且距离 ≤12 pt、scroll 3 pt、pinch 比例变化 6%。先判定后锁定 Scroll 或 Magnify，Mac 不重新猜手势。第三指、触点替换、系统取消和 Pencil / hover 抢占发 cancelled，全部抬起后才能重启；双指 tap 不产生撤销。

正常双指先后抬起时，第一根抬起只发一次 ended，剩余触点阻塞到全抬起，不转成单指点击/拖动。Scroll 的 began 坐标固定为原始两指中心，后续增量不移动 wheel 目标。GoodNotes 连续缩放在 ended / cancelled 时清空需求；其他公开分档适配器可在正常 ended 后完成有限已收到需求，cancelled 清空。执行安全边界见 [ARCHITECTURE](ARCHITECTURE.md)。

### 4.5 INPUT_CANCEL / GESTURE_KEEPALIVE / INPUT_REJECTED

- INPUT_CANCEL：`gestureID u64, reason u8`（9 B，与 INPUT_REJECTED 同布局；reason 为 §6 原因码）。
- GESTURE_KEEPALIVE：`gestureID u64, lastSampleSeq u32`。只要 iPad 认为手势仍活跃就定期发送，与是否移动无关。它**只延长手势存活**，不改变任何已收样本的年龄，也不能复活已结束的手势。

**输入新鲜度（Mac，只用本地单调时钟）**：每个输入帧在网络接收入口保留本地 `ReceiveStamp`。注入前独立检查两件事（`Sources/PadInkCore/Input/InputFreshness.swift`）：

1. 样本年龄 `now − ReceiveStamp ≤ maxQueueAge`（初值 100 ms）。超过 → 丢弃该样本，安全结束该手势，INPUT_REJECTED(staleSample)；此后该手势的所有样本（即使新鲜）都丢弃，iPad 必须重新落笔。
2. 手势存活：相邻两次收到该手势的样本或 keepalive 间隔必须**小于** `gestureTimeout`（初值 1 s）；间隔恰好等于它即过期。`deadline()` 返回的就是第一个过期时刻，一次性定时器恰好在该时刻触发即可释放手势。超时**不可逆**：Mac 的每个入口（收到样本、收到 keepalive、注入前判定、到期定时检查）都先在当前处理时间上判定截止时间，再处理消息。所以截止时间已过后才被处理的迟到消息不能刷新手势，无论定时检查是否先执行；结束只报告一次（INPUT_REJECTED(gestureTimeout)）。静止且没有后续消息的手势由 Mac 在截止时间安排的定时检查安全释放。

`maxQueueAge` 只衡量 Mac 本地排队（接收 → 注入），不衡量网络传输时间；网络卡顿表现为手势在两次到达之间的间隔，由手势存活判定。这些是当前实现策略默认值，不是对网络端到端延迟的保证。
- INPUT_REJECTED：`gestureID u64, reason u8`（9 B，§6 的 cancel 原因码）。iPad 收到后丢弃该手势后续样本并要求重新落下。

### 4.6 PRESENTED_GEOMETRY

`geometryGeneration u32 (>0), ready u8 (0/1), orientation u8, reserved u16, videoWidth u32, videoHeight u32`（16 B，已实现）。Mac 用它确认 iPad 已呈现的几何；不匹配的手势被拒绝（不是断开）。

### 4.7 VIDEO_CONFIG / VIDEO_FRAME / KEYFRAME_REQUEST

KEYFRAME_REQUEST 无 payload。VIDEO_CONFIG / VIDEO_FRAME 已实现（`Video/Video.swift`），沿用 Baseline 语义：`VIDEO_CONFIG = videoGeneration u32, width u32, height u32, spsLen u16, ppsLen u16, sps, pps`；`VIDEO_FRAME = videoGeneration u32, frameID u64, captureTime u64, AVCC`，IDR 置 KEYFRAME flag 且必须真的含 IDR NAL；每个 IDR 前有 config；解码端拒绝旧 generation 和缺口 P 帧。

扩展视频只在对端 HELLO 宣告 `extendedVideo` 时发送。未宣告的旧端保持原 H.264 / 最大 4096 路径，旧 H.264 config 字节不变。扩展端尺寸安全边界为每轴 8192（不是设备能力承诺）；HEVC config 在原 SPS/PPS 后追加 `codec u8=1, vpsLen u16, vps`，NAL 长度仍为 4 字节。H.264 keyframe 必须含 type 5，HEVC 必须含 type 19/20/21。接收端以 config 的 codec 验证帧，不得把 HEVC NAL 当 H.264。

`VIDEO_FEEDBACK = videoGeneration u32, width u32, height u32, codec u8, congested u8`（14 字节；兼容没有末尾压力字节的 13 字节确认），仅在 required-hardware decoder 产生实际图像后发送；设置成功或创建 session 不能发确认。Mac 核对 generation / codec / 实际尺寸；实验配置 8 秒无确认或编码失败则用更高 videoGeneration 重建原档位，保留 A 输入连接。反馈确认不代表画质改善、稳定 FPS 或 Pencil 性能验收。iPad 每秒最多追加一次带压力位的反馈（待解码帧达到 2、丢帧计数增加、等待 IDR、接收至显示超过 80 ms 或有新到达但超过 200 ms 未显示），Mac 将其与发送完成耗时/队列压力共同用于既有降级迟滞；仍不扩大任何队列。日常模式目标上限 20 Mbps；旧自定义与内部实验仍可超过该预算，普通 UI 不提供高码率实验编辑器；仍受编码 API 整数范围、8 MiB 单帧和有界队列约束。


## 5. 重连语义

- 每次传输附着递增**会话世代**（generation）。输入序号、手势 ID 不跨世代延续；旧世代的输入帧一律丢弃，**从不重放**。
- resumeToken：Mac 为逻辑会话生成 32 字节随机值，在 HELLO 中出示以恢复同一逻辑会话（保留几何、视频设置、UI 状态）。恢复只意味着“不重新走 UI 流程”，不意味着任何输入或视频帧被续传；视频总是从新 IDR 开始。
- resumeToken 必须与每对密钥认证绑定（AUTH_PROOF 的 transcript 覆盖它），否则无效。
- **只重建视频连接**（§1.1 第 7b 行）：Mac 关闭 B，用同一 attachmentID 与当前世代重新发起 B 的 HELLO（connectionKind = 2）。iPad 用新 B 替换旧 B。会话世代不变，A 上的输入不受影响；视频世代递增，从新 IDR 开始。B 的序号从 1 重新开始。重建 5 s 内未完成（无设备、HELLO 未确认、替换连接关闭）即视为失败，按 0.5 s 起翻倍、上限 10 s 的退避重试，期间附着保持。
- **解码恢复**：同一视频连接内，新 IDR 也会淘汰旧参考链的在途显示许可；旧帧超时或迟到失败不能清掉新链。每个视频 epoch 最多请求 8 次关键帧，耗尽后每次连续画面中断最多主动重建一次 B，保留 A 输入与认证。重建后仍失败则提示处理，实际重新呈现画面后恢复该预算。
- **A、B 到达顺序**：两条连接互相独立，iPad 可能先收到 B 的 HELLO。iPad 在握手超时内暂存它，A 到达后按 attachmentID、世代、设备匹配接纳；超时仍无匹配 A 才以 `attachmentMismatch` 拒绝。
- **本地关闭的原因**：一端主动关闭时携带 GOODBYE 原因；只有 `userDisconnect` 让 Mac 的逻辑会话暂停，其余（显示变化、权限缺失、睡眠、设置变化）在条件恢复后自动重连。

## 6. 错误语义

ERROR payload：`code u16, faultRow u8, reserved u8, detail u8 长度 + ASCII ≤ 200`（detail 只保留可打印 ASCII，不含窗口标题、文档名、路径）。code：1 versionMismatch、2 protocolViolation、3 authenticationFailed、4 attachmentMismatch、5 busy（已有活动连接）。

GOODBYE payload：`reason u8`：1 userDisconnect、2 appBackground、3 appQuit、4 forgetDevice、5 settingsChanged。`faultRow` 对应 [ARCHITECTURE §5](ARCHITECTURE.md) 故障分级表的行号，用于诊断。

| 类别 | 例子 | 处理 |
|---|---|---|
| 协议违规 / 认证失败 | magic、版本、序号、长度、未知 critical、错误连接、认证失败 | 断开该附着（唯一直接断开的类别） |
| 输入拒绝 | 几何世代不匹配、手势超时、过期样本、目标窗口消失 | INPUT_REJECTED，只结束该手势，会话保持 |
| 降级 | 视频积压、拥塞 | 不发错误；STATUS / VIDEO_PROFILE 报告 |

cancel 原因码（u8，诊断导出使用同一编码）：1 transportLost、2 gestureTimeout、3 geometryMismatch、4 staleSample、5 targetChanged、6 pencilPreempted、7 settingsChanged、8 appBackground、9 sessionReplaced、10 protocolViolation。视频拥塞与视频重建不产生 cancel 原因码（它们不取消输入），只记录为诊断事件 `videoCongested` / `videoRebuilt(reason)`。


A/B 最后认证帧可能跨连接异步到达：已认证 A 的初始产品帧保留原接收 stamp，暂存至两条连接均 ready，上限 32 帧 / 128 KiB；再先报告 ready、后按序交付。未认证流的产品帧仍拒绝。wireVersion 1/2 与 3 不能混用，提示两端一起更新。

## 7. 每对设备认证

App 必须成功读取 Keychain 身份后才启动传输；失败保持离线，不回退到临时身份或匿名模式。`Attachment` 的无 security 模式仅供原始连接测试，不用于两端 App。USB 产品流经 usbmuxd 访问 iPad loopback；Wi-Fi 产品流先完成 TLS（§8）。

每条 A/B 在 HELLO/HELLO_ACK 后独立交换认证，未完成时不放行任何产品输入/视频。首次 USB 配对，两端各确认一次（同一设备 A/B 请求合并）。已信任设备自动认证。首次认证总时限 120 s，为双端确认留时间；视频替换认证仍使用 5 s 重建时限。

- AUTH_PROOF offer：`01 | Curve25519 publicKey[32] | random nonce[32]`，65 字节。公钥 SHA-256 必须等于 HELLO deviceID，拒绝自身身份与重复 offer。
- 每对密钥：Curve25519 ECDH，HKDF-SHA256，salt 为按字节升序排列的两个 deviceID 拼接，info 为 UTF-8 `PadInk pair key v1`，输出 32 字节。
- AUTH_PROOF proof：`02 | HMAC-SHA256[32]`，33 字节。
- transcript：UTF-8 `PadInk auth v1` + NUL + `proof` + NUL + 发送者 role u8 + 完整 Mac HELLO payload + 完整 iPad HELLO payload + Mac nonce[32] + iPad nonce[32]。覆盖 A/B 类型、attachmentID、世代、resumeToken、版本、身份和能力。
- 本端确认且对方 proof 有效后，事务式保存 TrustStore，再发 AUTH_RESULT：相同 transcript，但标签为 `accepted`，纯 HMAC 32 字节。收到对方 accepted 后该流通过认证。未成功持久化不能启动产品通路。
- 新的认证生成新 nonce，旧连接 proof 不可重放到新连接或另一种角色/通道。Keychain service 保持 `dev.padink03.trust`，按当前 bundle ID 分别存 identity / peers；iPad 使用 ThisDeviceOnly；Mac 免费团队无 provisioned access group，使用不启用同步的本机 login Keychain，访问由稳定签名要求保护。两端均不启用云同步。
- 忘记某设备只移除其记录并结束对应活动连接，需用户明确“重新连接／允许重新配对”才能再次确认。App 重启后也必须重新确认已移除的设备。
- iPad 暂存新 A/B 候选，只有认证完成才替换当前会话。已连接会话的 B 替换也先认证；失败仅丢弃候选，保留 A 与原 B。后台化会关闭候选，迟到 UI 确认不能复活它。



当前视频策略：持续视频拥塞 1 s → 50% 码率，3 s → 30 fps；连续健康 10 s 恢复。视频光栅保持不变。heartbeat 的 `(t2-t1 + t3-t4)/2` 是诊断 offset，`((t4-t1)-(t3-t2))/2` 是 uncertainty；非法时间顺序不更新估计，uncertainty >25 ms 标记低精度，不阻止输入/视频。


## 8. LAN 安全承载与首次配对

产品连接使用 wireVersion 3，与 USB 的 PNK2 帧、消息和 A/B 语义完全一致。LAN 先建立 TLS 1.2 PSK（套件 `0x00a8`），PSK 为 `HKDF-SHA256(pairKey, salt="PadInk TLS v1", info=empty, length=32)`；PSK identity 为排序后的两端完整 deviceID 拼接后 SHA256 的 Base64。连接成功后仍须 §7 的设备认证。LAN 首次握手期限 3 秒，未通过不得送入产品处理器。

首次无线配对是独立的临时 TCP 入口，绝不能承载 PNK2 产品消息。iPad 主动开放，120 秒后关闭，每次开放最多一次连接尝试。uint16 大端长度头，payload 1…130 字节，接收缓冲上限 4096。消息如下：

| stage | payload（包含 stage） | 约束 |
|---|---|---|
| 1 | `01 + role:u8 + commitment:32` | 角色必须与本端相反，且只接受一次 |
| 2 | `02 + publicKey:32 + nonce:32 + nameLength:u8 + UTF8 name` | 名称最多 64 字节；先收到对方承诺才揭示；验证 commitment |
| 3 | `03 + HMAC-SHA256:32` | 仅本端用户确认 SAS 后发送；验证双方完整揭示及发送角色 |
| 4 | `04 + HMAC-SHA256:32` | 双方 consent 验证通过且本端 Keychain 保存成功后发送；收到对端保存回执才报告完成 |

commitment=`SHA256("PadInk SAS commitment v1" + role + revealBody)`。transcript=`"PadInk SAS v1\0" + label + "\0" + senderRole + MacReveal + iPadReveal`。SAS label=`code`、senderRole=0；摘要前四字节按大端 uint32 对 1,000,000 取模，显示六位十进制。consent/stored 的 label 分别为 `consent`/`stored`，发送角色写入 transcript，用 §7 的 ECDH pairKey 作 HMAC 密钥。用户拒绝、重复/越序/空消息、篡改、超时和保存失败均不可恢复到成功。

无一端长期 secret 经配对入口明文发送。双方的信任保存无法跨设备原子提交，断网时可以重新开始配对；仅持有单端回执绝不意味着产品连接可用。最终回执必须写入传输后才能关闭本端配对 socket。
