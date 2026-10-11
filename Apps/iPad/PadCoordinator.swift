#if canImport(UIKit)
import UIKit
import Combine
import PadInkCore
import PadInkTransport

/// iPad wiring: loopback listener -> PadAttachmentHost -> attachment; decode on a media queue that
/// never blocks input; Pencil batches, geometry and keepalives on the input queue (keepalives come
/// from this queue's timer, not the main thread — ARCHITECTURE §4.2).
public final class PadCoordinator {
 public let model = PadModel()
 public let diagnostics = Diagnostics()
 private let performanceWindow = PerformanceWindow()
 public let renderer: MetalRenderer?
 public weak var view: PencilView?
 private let queue = DispatchQueue(label: "pnk2.pad.input", qos: .userInteractive)
 private let media = DispatchQueue(label: "pnk2.pad.media", qos: .userInteractive)
 private var listener: USBListenerHost?, host: PadAttachmentHost?, timer: DispatchSourceTimer?
 private var lanHost: LANServiceHost?
 private var security: AttachmentSecurity?
 private var attachment: Attachment?
 private var transportPresentation = TransportPresentation()
 private var videoState = "idle", lastVideoError: String?
 private var videoRecovery: ConnectionPresentation?
 private var usbListenerState = "stopped", usbListenerError: String?
 private var videoWaitingSince: UInt64?
 private var keyframeRetry = VideoKeyframeRetry()
 private var keyframeExhaustionReported = false
 private var decodeRecoveryRebuilt = false
 private var decodedVideoConfig: VideoConfig?
 private var lastVideoFeedback: UInt64 = 0, lastFeedbackDrops: UInt64 = 0
 private var pendingKeyframeContext: VideoDecodeContext?
 private var videoContext: VideoDecodeContext? // Input queue; changes on attachment or B replacement.
 private lazy var videoPump = VideoDecodePump(schedule: { [weak self] job in self?.media.async { job() } })
 public var videoQueueSnapshot: VideoDecodeQueueSnapshot { videoPump.snapshot }
 private var touchEnabled = UserDefaults.standard.object(forKey: "touchEnabled") as? Bool ?? true
 private lazy var input = PadInputLink(diagnostics: diagnostics)
 private let signingExpiry = ProvisioningProfile.embeddedExpiry()
 private var drawable = CGSize(width: 2732, height: 2048)
 private var paused = false
 private var presentationID: UUID? // Main-thread only; fences delayed decoder callbacks.
 private var presentationVideoEpoch: UUID? // A B-only rebuild also retires decoder callbacks.
 /// Main-thread only: the attachment that input captured right now belongs to.
 private var inputContext: InputContext?

 public init() {
  do { renderer = try MetalRenderer(diagnostics: diagnostics) }
  catch {
   renderer = nil; videoState = "failed"; lastVideoError = "rendererUnavailable"; model.phase = .needsAttention
   model.videoNote = "无法初始化画面显示，请重新打开 PadInk；持续失败时请导出诊断"
  }
  let pixels = UIScreen.main.nativeBounds.size
  drawable = CGSize(width: max(pixels.width, pixels.height), height: min(pixels.width, pixels.height))
  let reminder = BuildIdentity.current.isDeveloperInstall ? ProvisioningProfile.reminder(expiry: signingExpiry) : nil
  DispatchQueue.main.async { [model] in model.signingReminder = reminder }
 }

 public func beginDiagnosticSession() {
  var status = SessionDiagnostics(); status.role = "ipad"
  status.model = HardwareModel.current; status.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
  status.applyBuild(BuildIdentity.current); diagnostics.updateSession(status)
  do {
   if try diagnostics.beginSessionRecovery() { model.previousSessionNote = "上次运行未正常结束：已保留有限诊断。可能是系统终止、强制退出或异常；请导出诊断，若曾闪退还需系统崩溃报告。" }
  } catch { diagnostics.fault(row: "8", reason: "diagnosticRecoveryUnavailable", generation: 0) }
 }
 public func endDiagnosticSession() { diagnostics.mark("app.normalExit"); diagnostics.finishSessionRecovery() }

 public func start() {
  queue.async { [self] in
   let security: AttachmentSecurity
   do {
    security = try KeychainIdentity.load(); self.security = security
    security.onChange = { [weak self] in self?.refreshTrustUI(); self?.lanHost?.refreshKeys() }; refreshTrustUI()
   } catch { ui { $0.phase = .needsAttention; $0.status = "设备身份无法读取：请退出并重新打开 PadInk；持续失败时请导出诊断" }; return }
   let host = PadAttachmentHost(local: { [weak self] in self?.identity() ?? LocalIdentity(appVersion: "0.3.0-dev", deviceID: security.identity.id) }, security: security, queue: queue)
   host.onAttachment = { [weak self] a in self?.adopt(a) }
   host.onReject = { [weak self] end in
    self?.diagnostics.mark("session.rejected", state: String(describing: end))
    let presentation = ConnectionPresentation.ended(end, peer: "Mac")
    self?.ui { if !$0.sessionActive { $0.phase = presentation.phase; $0.status = presentation.message } }
   }
   self.host = host
   let lan = LANServiceHost(security: security, name: UIDevice.current.name, queue: queue); lanHost = lan
   lan.onStream = { [weak self] stream in guard let self, !self.paused else { stream.close(); return }; host.accept(stream, transport: .wifi) }
   lan.onStatus = { [weak self] note in self?.ui { $0.lanNote = note } }
   lan.onPairPrompt = { [weak self] prompt in self?.ui { $0.lanPairing = prompt } }
   lan.refreshKeys()
   let usb = USBListenerHost(queue: queue)
   usb.onStream = { [weak self] stream in
    guard let self, !self.paused else { stream.close(); return }; host.accept(stream)
   }
   usb.onState = { [weak self] state in
    guard let self else { return }
    self.usbListenerState = state.diagnosticCode
    if let reason = state.errorCode { self.usbListenerError = reason }
    self.diagnostics.mark("usb.listener", state: state.diagnosticCode + (state.errorCode.map { ":" + $0 } ?? ""))
    let note: String?
    switch state {
    case .retrying: note = "USB 连接服务暂不可用，正在自动恢复；Wi-Fi 仍可使用"
    case .waiting: note = "USB 连接服务正在等待系统恢复；Wi-Fi 仍可使用"
    default: note = nil
    }
    self.ui { if $0.usbNote != note { $0.usbNote = note } }
   }
   listener = usb; if !paused { usb.start() }
   let t = DispatchSource.makeTimerSource(queue: queue); t.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
   t.setEventHandler { [weak self] in self?.tick() }; timer = t; t.resume()
  }
 }

 /// App left the foreground: end the stroke locally, say goodbye, stop accepting until active again.
 public func suspend() {
  view?.cancelContact(reason: "app background")
  queue.async { [self] in paused = true; listener?.stop(); lanHost?.stop(); host?.closeAll(.appBackground); diagnostics.checkpointSessionRecovery(force: true) }
 }
 public func resume() { queue.async { [self] in paused = false; listener?.start(); lanHost?.refreshKeys() } }
 public func setTouchEnabled(_ enabled: Bool) {
  model.touchEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "touchEnabled"); view?.touchEnabled = enabled
  queue.async { [self] in touchEnabled = enabled; _ = attachment?.send(.inputSettings, payload: InputSettings(touchEnabled: enabled).encoded(), on: .controlInput) }
 }
 public func setDrawable(_ size: CGSize) { queue.async { [self] in if size.width > 0, size.height > 0 { drawable = CGSize(width: max(size.width, size.height), height: min(size.width, size.height)) } } }

 // MARK: View callbacks (main thread)

 public func bind(_ view: PencilView) {
  self.view = view
  view.touchEnabled = model.touchEnabled
  let callbacks = PadInputCallbacks(link: input, context: { [weak self] in self?.inputContext },
   enqueue: { [weak self] job in self?.queue.async { job() } })
  view.configureTouch(send: callbacks.touch, gesture: callbacks.touchGesture)
  view.renderer = renderer; view.delegate = renderer; view.diagnostics = diagnostics
  renderer?.willRenderGeometry = { [weak view] g in view?.willRender(g) ?? 0 }
  renderer?.didPresentGeometry = { [weak self, weak view] g in
   view?.didPresent(generation: g)
   guard let self, let inputContext = self.inputContext, let epoch = self.presentationVideoEpoch else { return }
   let context = VideoDecodeContext(attachment: inputContext, epoch: epoch)
   guard self.model.videoPresented() else { return }
   self.queue.async { [weak self] in
    guard let self, self.videoContext == context else { return }
    self.keyframeRetry = VideoKeyframeRetry(); self.keyframeExhaustionReported = false; self.decodeRecoveryRebuilt = false
    self.videoState = "presenting"; self.videoWaitingSince = nil; self.videoRecovery = nil
    self.performanceWindow.arm(inputContext, diagnostics: self.diagnostics, queue: self.queue, isCurrent: { [weak self] in self?.videoContext == context }, begin: { [weak self] in
     guard PerformanceExperiment.mode == .noRender else { return }
     DispatchQueue.main.async {
      guard let self, self.inputContext == inputContext else { return }
      self.renderer?.performanceRenderingPaused = true
     }
    })
   }
  }
  input.onRejected = { [weak self] context, notice in
   DispatchQueue.main.async {
    guard let self, self.inputContext == context else { return }
    self.view?.rejected(gestureID: notice.gestureID, reason: notice.reason)
    self.model.lastInputNote = Self.describe(notice.reason)
   }
  }
  input.onStall = { [weak self] context in
   DispatchQueue.main.async {
    guard let self, self.inputContext == context else { return }
    self.model.lastInputNote = "输入发送停滞，已安全结束并重新连接，请稍后重新落笔"
   }
  }
  view.send = { [weak self] samples in
   guard let self else { return }
   for s in samples { self.diagnostics.mark("input.capture", sample: s) }
   callbacks.pencil(samples)
  }
  view.sendGeometry = callbacks.geometry
  view.gestureState = callbacks.pencilGesture
 }

 // MARK: Queue

 private func identity() -> LocalIdentity {
  LocalIdentity(appVersion: BuildIdentity.current.wireVersion, deviceID: security!.identity.id, displayName: UIDevice.current.name, capabilities: [.pencilPressure, .pencilTilt, .extendedVideo], signingExpiry: signingExpiry, drawableWidth: UInt32(drawable.width), drawableHeight: UInt32(drawable.height))
 }

 private func tick() {
  host?.tick()
  var status = SessionDiagnostics(); status.role = "ipad"; status.transport = attachment?.transport.rawValue ?? "none"
  status.connection = attachment?.isReady == true ? "active" : "waiting"; status.generation = attachment?.generation ?? 0
  status.peerID = attachment?.peer?.deviceID.prefix(6).map { String(format: "%02x", $0) }.joined()
  status.peerAppVersion = attachment?.peer?.appVersion; status.signingExpiry = signingExpiry
  status.rttMilliseconds = attachment?.controlRTT.map { Double($0) / 1e6 }; status.clock = attachment?.clockEstimate
  status.inputOwner = input.pencilGesture != nil ? "pencil" : input.touchGesture != nil ? "touch" : "none"; status.gesture = input.pencilGesture?.0 ?? input.touchGesture?.0
  status.model = HardwareModel.current; status.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString; status.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0-dev"
  status.sourceBuild = BuildIdentity.current.source; status.videoState = videoState; status.lastVideoError = lastVideoError
  status.usbListenerState = usbListenerState; status.usbListenerError = usbListenerError
  let video = videoPump.snapshot
  let now = MonotonicClock.now
  if let config = decodedVideoConfig, let a = attachment, a.isReady,
     a.peer?.capabilities.contains(.extendedVideo) == true, now &- lastVideoFeedback >= 1_000_000_000 {
   let pressure = video.pendingFrames >= 2 || video.droppedFrames > lastFeedbackDrops || video.waitingForIDR || renderer?.presentationPressure.congested(now: now) == true
   _ = a.send(.videoFeedback, payload: VideoFeedback(config, congested: pressure).encode(), on: .video)
   lastVideoFeedback = now; lastFeedbackDrops = video.droppedFrames
  }
  status.decodePendingFrames = video.pendingFrames; status.decodePendingBytes = video.pendingBytes; status.decodeInFlightBytes = video.inFlightBytes
  status.decodePeakPendingFrames = video.peakPendingFrames; status.decodePeakRetainedBytes = video.peakRetainedFrameBytes
  status.decodeDroppedFrames = video.droppedFrames; status.decodeRecoveries = video.recoveries
  status.decodeWaitingForIDR = video.waitingForIDR; status.decodeWorkers = video.scheduledWorkers
  let inputQueue = input.queueSnapshot
  status.inputPendingFrames = inputQueue.captureFrames + inputQueue.pendingFrames
  status.inputPendingBytes = inputQueue.captureBytes + inputQueue.pendingBytes
  status.inputInFlightBytes = inputQueue.inFlightBytes; status.inputOldestAgeMilliseconds = inputQueue.oldestAgeMilliseconds
  status.inputDroppedGestures = inputQueue.droppedGestures; status.inputStalls = inputQueue.stalls
  status.applyBuild(BuildIdentity.current)
  diagnostics.updateSession(status)
  diagnostics.checkpointSessionRecovery()
  if let waiting = videoWaitingSince, MonotonicClock.now &- waiting >= 3_000_000_000, let context = videoContext {
   if video.waitingForIDR { pendingKeyframeContext = context }
   let recovery = videoRecovery
   let unavailable = renderer == nil
   DispatchQueue.main.async { [weak self] in
    guard let self, self.presentationVideoEpoch == context.epoch, self.videoPump.isCurrent(context) else { return }
    self.model.phase = unavailable ? .needsAttention : recovery?.phase ?? .recovering
    self.model.videoNote = unavailable ? "无法初始化画面显示，请重新打开 PadInk；持续失败时请导出诊断" : recovery?.message ?? "连接仍在，但尚未收到可显示画面；正在请求恢复。持续无画面时请查看 Mac 状态并导出双端诊断"
   }
  }
  input.tick(); requestPendingKeyframe()
 }

 private func adopt(_ a: Attachment) {
  performanceWindow.reset(); decodeRecoveryRebuilt = false
  attachment = a; a.performance = diagnostics.performance; input.adopt(a)
  ui { if !$0.sessionActive { $0.phase = .connecting; $0.status = "正在与 Mac 建立安全连接…" } }
  a.onEvent = { [weak self, weak a] event in guard let self, let a, self.attachment === a else { return }; self.handle(event, a) }
 }

 private func handle(_ event: AttachmentEvent, _ a: Attachment) {
  let g = UInt64(a.generation)
  switch event {
  case .ready(let peer):
   a.recordPerformanceRoutes()
   _ = a.send(.inputSettings, payload: InputSettings(touchEnabled: touchEnabled).encoded(), on: .controlInput)
   let decoder = startVideo(a), context = videoContext!
   diagnostics.mark("session.ready", session: g)
   let connectionName = a.transport == .usb ? "USB" : "Wi-Fi"
   let notice = transportPresentation.confirmed(a.transport, peer: peer.deviceID)
   ui { [weak self] model in model.sessionActive = true; model.transportNotice = notice; model.transport = connectionName; model.peerVersion = peer.appVersion; model.macName = peer.displayName; model.status = "已连接 · \(connectionName)，等待画面…"; model.phase = self?.renderer == nil ? .needsAttention : .waitingForVideo; model.videoNote = self?.renderer == nil ? "无法初始化画面显示，请重新打开 PadInk；持续失败时请导出诊断" : "正在接收画面…"; model.lastInputNote = nil; model.connected = false
    // A new attachment starts from clean capture state: nothing captured under the previous one
    // (including one replaced without an ended event, possibly with the same generation) continues.
    if self?.inputContext != InputContext(a) { self?.view?.session = 0 }
    self?.inputContext = InputContext(a); self?.presentationID = a.attachmentID; self?.presentationVideoEpoch = context.epoch; self?.renderer?.inputContext = InputContext(a); self?.renderer?.session = g; self?.renderer?.replaceVideoSource(decoder.latest, epoch: context.epoch); UIApplication.shared.isIdleTimerDisabled = true }
   if notice != nil { clearTransportNotice(after: a) }
  case .frame(.video, let f, let stamp):
   if performanceWindow.active, PerformanceExperiment.mode == .noDecode {
    diagnostics.performance.record(PerformanceEvent("video.experimentDiscard", generation: g, attachment: a.attachmentID, stream: ConnectionKind.video.rawValue, frame: f.sequence, bytes: f.payload.count, code: "no-decode")); break
   }
   if let context = videoContext { if f.type == .videoFrame { renderer?.presentationPressure.received(epoch: context.epoch, now: MonotonicClock.now) }; _ = videoPump.push(f, context: context, received: stamp.localTime) }
  case .frame(.controlInput, let f, _):
   if f.type == .inputRejected, let notice = try? GestureNotice(f.payload) {
    input.rejected(notice)
    let context = InputContext(a)
    DispatchQueue.main.async { [weak self] in
     guard let self, self.inputContext == context else { return }
     self.view?.rejected(gestureID: notice.gestureID, reason: notice.reason); self.model.lastInputNote = Self.describe(notice.reason)
    }
   }
  case .videoRebuilt:
   let decoder = startVideo(a), context = videoContext!
   DispatchQueue.main.async { [weak self] in
    guard let self, self.presentationID == context.attachment.attachmentID, self.videoPump.isCurrent(context) else { return }
    self.presentationVideoEpoch = context.epoch; self.renderer?.replaceVideoSource(decoder.latest, epoch: context.epoch); self.model.phase = .recovering; self.model.status = "已连接 · \(self.model.transport)，画面恢复中"; self.model.videoNote = "画面连接正在恢复；输入连接仍在"
   }
  case .ended(let end):
   diagnostics.fault(row: end.diagnosticFault.row, reason: end.diagnosticFault.reason, generation: UInt32(g))
   diagnostics.mark("session.ended", session: g, state: String(describing: end))
   attachment = nil; input.ended(a); videoState = "idle"; videoWaitingSince = nil
   decodedVideoConfig = nil
   videoContext = nil; pendingKeyframeContext = nil; videoPump.deactivate()
   let presentation = ConnectionPresentation.ended(end, peer: "Mac")
   DispatchQueue.main.async { [weak self] in guard let self else { return }
    self.inputContext = nil; self.presentationID = nil; self.presentationVideoEpoch = nil; self.view?.session = 0; self.renderer?.clear(); self.renderer?.latest = nil; self.renderer?.inputContext = nil; self.renderer?.session = 0
    self.model.connected = false; self.model.sessionActive = false; self.model.phase = presentation.phase; self.model.transportNotice = nil; self.model.status = presentation.message; self.model.videoNote = nil; UIApplication.shared.isIdleTimerDisabled = false }
  default: break
  }
 }

 /// Input queue. Replacing B creates a new decode epoch without changing input ownership.
 @discardableResult private func startVideo(_ a: Attachment) -> VideoDecoder {
  let context = VideoDecodeContext(attachment: InputContext(a)), g = UInt64(a.generation)
  decodedVideoConfig = nil; lastVideoFeedback = 0; lastFeedbackDrops = videoPump.snapshot.droppedFrames
  videoContext = context; pendingKeyframeContext = nil; keyframeRetry = VideoKeyframeRetry(); keyframeExhaustionReported = false; videoRecovery = nil
  if renderer != nil { videoState = "waitingForFrame"; videoWaitingSince = MonotonicClock.now }
  else { videoState = "failed"; videoWaitingSince = nil }
  let decoder = VideoDecoder(session: g, diagnostics: diagnostics)
  let recover: () -> Void = { [weak self, weak a] in
   if let self {
    self.diagnostics.performance.record(PerformanceEvent("video.decodeRecoveryCause", generation: g, code: self.videoPump.snapshot.lastRecoveryReason))
   }
   self?.queue.async {
    guard let self, let a, self.attachment === a, self.videoContext == context else { return }
    self.diagnostics.mark("video.recoveryRequested", session: g, value: Double(self.videoPump.snapshot.droppedFrames))
    self.videoState = "recovering"; self.videoWaitingSince = self.videoWaitingSince ?? MonotonicClock.now
    self.pendingKeyframeContext = context; self.requestPendingKeyframe()
    let recovery = self.videoRecovery ?? ConnectionPresentation(phase: .recovering, message: "画面解码正在恢复；输入连接仍在。持续失败时请导出双端诊断")
    DispatchQueue.main.async { [weak self] in
     guard let self, self.presentationVideoEpoch == context.epoch, self.videoPump.isCurrent(context) else { return }
     self.model.phase = recovery.phase; self.model.status = "已连接 · \(self.model.transport)，解码恢复中"; self.model.videoNote = recovery.message
    }
   }
  }
  decoder.onDecodedConfig = { [weak self] config in
   self?.queue.async { [weak self] in
    guard let self, self.videoContext == context, let a = self.attachment, a.peer?.capabilities.contains(.extendedVideo) == true else { return }
    self.decodedVideoConfig = config
    _ = a.send(.videoFeedback, payload: VideoFeedback(config).encode(), on: .video)
   }
  }
  decoder.onRecovery = { [weak self] generation, frameID in self?.videoPump.invalidate(context, generation: generation, frameID: frameID) }
  decoder.onFirstFrame = { [weak self] in
   DispatchQueue.main.async {
    guard let self, self.presentationID == context.attachment.attachmentID,
          self.presentationVideoEpoch == context.epoch, self.videoPump.isCurrent(context), self.renderer != nil, let view = self.view else { return }
    view.session = g; self.model.connected = true
   }
  }
  videoPump.activate(context, consume: { [weak self, decoder] frame, received, permit in
   guard permit() else { return }
   let started = MonotonicClock.now
   self?.diagnostics.performance.record(PerformanceEvent("video.mediaQueue", time: started, generation: g, attachment: context.attachment.attachmentID, link: context.epoch, stream: ConnectionKind.video.rawValue, frame: frame.sequence, start: received, end: started))
   do {
    if frame.type == .videoConfig { try decoder.configure(VideoConfig(frame.payload)) }
    else { try decoder.decode(VideoFrame(payload: frame.payload, keyframe: frame.flags.contains(.keyframe), codec: decoder.codec), received: received, shouldPresent: permit) }
   } catch {
    let code: String
    if case DecodeError.codec(let status) = error { code = "decodeCodec_\(status)" }
    else if case DecodeError.hardware = error { code = "hardwareDecoderUnavailable" }
    else { code = "decodePayloadFailure" }
    self?.diagnostics.mark("video.error", session: g, state: code)
    self?.queue.async { [weak self] in
     guard let self, self.videoContext == context else { return }
     self.lastVideoError = code
     self.videoRecovery = code == "hardwareDecoderUnavailable"
      ? ConnectionPresentation(phase: .needsAttention, message: "iPad 硬件视频解码不可用：请重新打开 iPad 上的 PadInk；持续失败时请导出双端诊断")
      : ConnectionPresentation(phase: .recovering, message: "iPad 画面解码失败，正在自动恢复；持续失败时请导出双端诊断，再重新打开两端")
    }
    var payload = ByteReader(frame.payload)
    let generation = try? payload.u32()
    let frameID = frame.type == .videoFrame ? try? payload.u64() : nil
    self?.videoPump.invalidate(context, generation: generation, frameID: frameID)
   }
  }, reset: { [decoder] in decoder.reset() }, recovery: recover)
  return decoder
 }

 /// Eight keyframe requests per video epoch, then one B-only restart per presentation outage.
 /// Persistent decode failure cannot cause endless redials; actual presentation resets the budget.
 private func requestPendingKeyframe() {
  guard let context = pendingKeyframeContext, context == videoContext, let a = attachment,
        InputContext(a) == context.attachment else { pendingKeyframeContext = nil; return }
  guard videoPump.snapshot.waitingForIDR else { pendingKeyframeContext = nil; return }
  let now = MonotonicClock.now
  guard keyframeRetry.takeAttempt(now: now) else {
   if keyframeRetry.attempts == 8, !keyframeExhaustionReported {
    keyframeExhaustionReported = true
    diagnostics.mark("video.recoveryExhausted", session: UInt64(a.generation))
    if !decodeRecoveryRebuilt, a.restartVideoAfterDecodeFailure() {
     decodeRecoveryRebuilt = true; pendingKeyframeContext = nil
     videoRecovery = ConnectionPresentation(phase: .recovering, message: "关键帧未能恢复画面，正在重建视频连接；输入连接仍在")
     diagnostics.mark("video.decodeRestart", session: UInt64(a.generation))
     return
    }
    DispatchQueue.main.async { [weak self] in
     guard let self, self.presentationVideoEpoch == context.epoch, self.videoPump.isCurrent(context) else { return }
     self.model.phase = .needsAttention
     self.model.videoNote = "关键帧恢复重试已达上限；输入连接仍在。等待画面自然恢复，持续无画面时请重新连接并导出诊断。"
    }
   }
   return
  }
  if a.send(.keyframeRequest, on: .video) {
   // A successful send is not proof of recovery; only actual presentation resets the budget.
   diagnostics.mark("video.decodeRecovery", session: UInt64(a.generation))
  }
 }

 public func beginWiFiPairing() { queue.async { [self] in lanHost?.beginPairing() } }
 public func confirmWiFiPairing(_ accepted: Bool) { queue.async { [self] in lanHost?.confirmPairing(accepted) } }
 public func confirmPairing(_ request: PairingRequest, accepted: Bool) {
  queue.async { [self] in security?.confirm(request.deviceID, accepted: accepted) }
 }
 public func allowPairing() { queue.async { [self] in security?.allowNewPairing(); ui { if !$0.sessionActive { $0.phase = .waiting; $0.status = "已允许重新配对：请在 Mac 上点“重新连接”" } } } }
 public func forgetDevice(_ peer: PairingRequest) {
  queue.async { [self] in
   do {
    try security?.forget(peer.deviceID)
    if attachment?.peer?.deviceID == peer.deviceID { attachment?.close(.forgetDevice) }
    ui { if !$0.sessionActive { $0.phase = .paused; $0.status = "已忘记设备：请允许重新配对，再在 Mac 点“重新连接”" } }
   } catch { ui { $0.lastInputNote = "无法保存设备设置，请重试" } }
  }
 }
 private func refreshTrustUI() {
  guard let security else { return }
  let request = security.requests.first, devices = security.store.peers.map { PairingRequest(deviceID: $0.deviceID, name: $0.name) }
  ui { $0.pairing = request; $0.trustedDevices = devices; if request != nil { $0.phase = .needsAttention; $0.status = "请在 Mac 和 iPad 两端确认 USB 配对" } }
 }

 public func exportDiagnostics() {
  guard !model.exportingDiagnostics else { return }
  model.exportingDiagnostics = true; model.exportURL = nil; model.exportNote = "正在生成诊断…"
  DispatchQueue.global(qos: .utility).async { [self] in
   let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
   do { let url = try diagnostics.export(to: dir); ui { $0.exportingDiagnostics = false; $0.exportURL = url; $0.exportNote = "诊断已生成：点“分享 iPad 诊断文件”保存或发送；也请导出 Mac 端诊断" } }
   catch { ui { $0.exportingDiagnostics = false; $0.exportNote = "诊断导出失败：请检查 iPad 可用储存空间，再重试（\(error.localizedDescription)）" } }
  }
 }
 private func clearTransportNotice(after a: Attachment) {
  queue.asyncAfter(deadline: .now() + 8) { [weak self, weak a] in
   guard let self, let a, self.attachment === a else { return }; self.ui { $0.transportNotice = nil }
  }
 }

 private func ui(_ change: @escaping (PadModel) -> Void) { DispatchQueue.main.async { [model] in change(model) } }
 static func describe(_ reason: CancelReason) -> String {
  switch reason {
  case .geometryMismatch: return "画面尺寸刚刚变化，这一笔未写入，请重新落笔"
  case .staleSample, .gestureTimeout: return "这一笔延迟过大已安全结束，请重新落笔"
  case .targetChanged: return "Mac 前台应用切换，当前笔画已安全结束"
  default: return "当前笔画已安全结束，请重新落笔"
  }
 }
}
#endif
