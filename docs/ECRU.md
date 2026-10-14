# Ecru 双指导航

PadInk 的 Ecru 适配使用 Ecru 原生 PDFKit 缩放，不使用 Goodnotes 的 Command+像素滚轮换算，也不注入私有 magnify 事件。

当前日用配套构建查询（2026-10-13）：Ecru Dev **0.5.0 / build 21**，`PadInkGestureBridgeVersion = 1`。这是配套版本标识，不自动扩大既有验收范围；Ecru 须单独安装，PadInk 安装包不包含它。其他 Ecru 构建需核对下述 bundle ID 与 bridge v1。

## 输入路径

- iPad `GestureFSM` 保留首次双指中心；捏合确定后发送逐次 `log(distance / previousDistance)`。距离不变、中心移动时仍发送零缩放量的 magnify 更新。
- Mac `TouchOwnership` 的时效、几何版本、Pencil 优先级和取消规则照常生效。仅精确匹配 Ecru 正式版 `local.leafink.reader.development` 与开发版 `local.ecru.reader.development` 的 Ecru 进入 `EcruNativeZoom`；其他应用继续使用现有 ZoomController。
- 开始手势时检查 Ecru bundle 的 `PadInkGestureBridgeVersion = 1`。每次发送前复核前台进程和原先聚焦的 AX 窗口。事件直接 `CGEvent.postToPid`，无网络监听、无按键修饰符。
- Ecru 窗口内监视器接收专用事件，将 Quartz 全局左上坐标转换为当前主键窗口坐标。因为进程定向事件没有 windowNumber，不能按普通 `event.window` 路由。
- 在改变 `PDFView.scaleFactor` 前记录上一中心的 PDF 页坐标，按 `exp(logDelta)` 缩放，再调整 clip view，使该点位于新的中心。滚动位置约束遵循 NSClipView，达到文档边界时允许自然的锚点偏移。
- Ecru 的独立双指平移也走同一原生路径，以零 logDelta 和移动中心实现直接跟手的二维平移，保留小数精度；无需依赖系统自然滚动设置。其他应用的像素滚轮路径不变。书写、橡皮、选择等正在进行时，Ecru 拒绝导航。

## 本地 bridge v1

这是两端约定的公开 CGEvent 字段载荷，不是系统原生 magnify 格式：

| 字段 | 值 |
| --- | --- |
| type | scrollWheel |
| eventSourceUserData | `0x50494E4B0001` |
| scrollWheelEventPointDeltaAxis3 | `round(logDelta * 1_000_000)` |
| scrollWheelEventScrollPhase | began=1, changed=2, ended=4, cancelled=8 |
| scrollWheelEventIsContinuous | 1 |
| location | 当前手势中心，Quartz 全局坐标 |
| flags、axis1、axis2 | 0 |

接收端仅允许从 PDF canvas 开始；窗口失焦、落笔、终止、取消或超过 250ms 的陈旧事件会清除手势。没有有效 began 的 changed 被忽略。单次 logDelta 必须有限且绝对值不超过 1，缩放限制为 Ecru 现有的 15%–600%。

## 验证

PadInk：`swift test`，以及 `EcruNativeZoomTests`、`TouchTests`、现有 Zoom/Touch/Pencil 回归测试。

Ecru：在 Ecru 工程执行 `zsh Scripts/test-padink.sh`。该测试通过真实 macOS 事件队列向独立测试进程投递专用缩放事件，并验证 PDFKit 比例、锚点、移动中心、取消、普通滚动及 tablet 书写。使用隔离数据目录和合成 PDF；结果在 `output/padink-gesture-results.json`。触摸体验仍须在实体 iPad 验证。

手动检查：缓慢连续放大和缩小；围绕同一个字捏合；捏合中移动中心；单独双指横向/纵向移动；Pencil 写字、擦除及套索；切换到 Goodnotes/预览检查已有输入。文档小于视口或已到边界时，中心受滚动边界限制。

### 2026-10-11 实测结果

- 2026-10-11 当时 PadInk 全量 Swift 检查共 527 项，6 项跳过、零失败；跳过项包含需显式开启的真机/资源实验，不代表这些实验已通过。构建与自动检查不能代替后续 Beta 2 / build 9 公开包的实体 iPad 验收。
- Ecru 独立进程实窗回放 11 项通过：60 次连续更新、1.4 倍比例、反向还原、移动中心、二维平移、取消和 Pencil 抢占。锚点计算最大误差约 `3.1e-12` Mac 点；这是 PDFKit 坐标测量，不代表视频或肉眼体验误差。
- Ecru 既有批注实窗回归 84 项通过，覆盖手写、压力、擦除、套索、撤销/重做、旋转裁剪页、批注显示与保存。
- 实体 iPad Air 5 已安装测试版 PadInk，Mac PadInk 与 Ecru 已更新。用户完成 USB 操作检查，反馈“没问题，用的 USB”。本轮没有把 Wi-Fi 体验视为已验证。
- Mac Shadowrocket VPN 全程保持连接。自动测试结果和 USB 反馈保存在 PadInk 的 `build/ecru/validation/`。
