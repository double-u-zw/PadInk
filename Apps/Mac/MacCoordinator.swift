#if os(macOS)
import AppKit
import Combine
import Network
import PadInkCore
import PadInkTransport

/// UI state for the menu-bar app (R2). Main thread only.
public final class MacModel: ObservableObject {
 @Published public var usbVideo = MacCoordinator.savedVideo(.usb)
 @Published public var wifiVideo = MacCoordinator.savedVideo(.wifi)
 @Published public var videoSettingsNote = "当前档位保持原样；更高画质需在本机验证。"
 @Published public var status = "等待 iPad 连接"
 @Published public var videoNote: String?
 @Published public var usbNote: String?
 @Published public var peerVersion: String?
 public let buildIdentity = BuildIdentity.current
 public let localVersion = BuildIdentity.current.display
 @Published public var previousSessionNote: String?
 @Published public var transport = "USB"
 @Published public var lanDevices: [PairingRequest] = []
 @Published public var lanPairing: LANPairingPrompt?
 @Published public var lanNote: String?
 @Published public var zoomNote: String?
 @Published public var pairing: PairingRequest?
 @Published public var trustedDevices: [PairingRequest] = []
 @Published public var connected = false
 @Published public var phase: ConnectionPhase = .waiting
 @Published public var transportNotice: String?
 @Published public var peerName = ""
 @Published public var raster = ""
 @Published public var screenRecordingGranted = false
 @Published public var accessibilityGranted = false
 @Published public var paused = false
 @Published public var signingWarning: String?
 @Published public var lastInputNote: String?
 @Published public var exportMessage: String?
 @Published public var exportURL: URL?
 @Published public var exportingDiagnostics = false
 @Published public var needsUpdate: String?
 public init() {}
}

/// Wires LogicalSession, Attachment, InputOwnership, PencilInjectionBackend and video together and
/// executes their decisions. Owns no business rules of its own (ARCHITECTURE §1). Every field below
/// `model` is confined to `queue`.
public final class MacCoordinator {
 public let model = MacModel()
 public let diagnostics = Diagnostics()
 private lazy var performanceObserver = InputPerformanceObserver(diagnostics: diagnostics)
 private let performanceWindow = PerformanceWindow()
 private var performanceVideoStopped = false
 private let queue = DispatchQueue(label: "pnk2.mac.input", qos: .userInteractive)
 private let discovery = DispatchQueue(label: "pnk2.mac.discovery", qos: .utility)
 private var session = LogicalSession(resumeToken: LogicalSession.newToken())
 private var lanDiscovery: LANDiscovery?, lanPairing: LANPairingSocket?, lanPeers: [LANPeer] = [], activeLANPeer: LANPeer?
 private var selection = TransportSelection(), usbChecking = false, lastUSBCheck: UInt64 = 0
 private var transportPresentation = TransportPresentation()
 private var preferredLANPeer: Data?, lanFailures = 0
 private var usbDialStage: USBDialer.Stage?, usbDialError: String?, usbDeviceCount: Int?, usbDialAttempts: UInt64 = 0
 private var usbAttachmentError: String?
 private var pendingUSB: (device: USBMux.Device, control: FDStream, video: FDStream)?
 private var security: AttachmentSecurity?
 private var attachment: Attachment?, device: USBMux.Device?
 private lazy var backend = PencilInjectionBackend(diagnostics: diagnostics)
 private lazy var pencil: PencilInputPipeline = {
  let p = PencilInputPipeline(backend: backend, diagnostics: diagnostics)
  p.sendReject = { [weak self] n in _ = self?.attachment?.send(.inputRejected, payload: n.encoded(), on: .controlInput) }
  p.scheduleDeadline = { [weak self] d in self?.scheduleDeadline(d) }
  p.onRelease = { [weak self] reason in if reason != .transportLost && reason != .sessionReplaced { self?.ui { $0.lastInputNote = Self.describe(reason) } } }
  return p
 }()
 private var applicationStrategy = "nativePencil"
 private lazy var zoom: ZoomController = {
  let z = ZoomController(queue: queue, probe: { [weak self] permit in
   try ApplicationZoomTarget.probe(permit, pixelEventReport: { event, ticket in
    self?.diagnostics.mark("zoom.pixelEvent", session: UInt64(ticket.context?.input.generation ?? 0), item: ticket.context?.gestureID ?? 0,
     state: "flags=\(event.flags.rawValue);phase=\(event.getIntegerValueField(.scrollWheelEventScrollPhase));continuous=\(event.getIntegerValueField(.scrollWheelEventIsContinuous));units=pixel",
     value: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
     viewX: Double(event.location.x), viewY: Double(event.location.y), eventType: event.type.rawValue)
   }) { stage, value in self?.diagnostics.mark("zoom.probe", state: stage, value: value) }
  })
  z.onStage = { [weak self] context, job, stage, time in
   self?.diagnostics.mark("zoom." + stage, session: UInt64(context.input.generation), item: context.gestureID ?? 0, time: time,
    state: "attachment=\(context.input.attachmentID);action=\(context.actionID);job=\(job?.uuidString ?? "none");target=\(context.targetRevision);geometry=\(context.geometryGeneration)")
  }
  z.onFailure = { [weak self] code in self?.diagnostics.mark("zoom.failure", state: code) }
  z.onSubmitted = { [weak self] command in self?.diagnostics.mark("zoom.commandSubmitted", state: command.rawValue) }
  z.onStatus = { [weak self] note in self?.ui { $0.zoomNote = note } }
  z.onStrategy = { [weak self] strategy in self?.applicationStrategy = strategy; self?.diagnostics.mark("app.strategy", state: strategy) }
  return z
 }()
 private lazy var pointerBackend: PointerInjectionBackend = {
  let p = PointerInjectionBackend(postEvent: { [weak self] event in
   self?.diagnostics.mark("touch.cgEvent", state: event.type == .scrollWheel ? "phase=\(event.getIntegerValueField(.scrollWheelEventScrollPhase));flags=\(event.flags.rawValue)" : nil,
     value: event.type == .scrollWheel ? Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) : nil,
     viewX: Double(event.location.x), viewY: Double(event.location.y), eventType: event.type.rawValue)
   event.post(tap: .cghidEventTap)
  }); return p
 }()
 private lazy var touch: TouchInputPipeline = {
  let p = TouchInputPipeline(backend: pointerBackend, diagnostics: diagnostics)
  p.sendReject = { [weak self] n in _ = self?.attachment?.send(.inputRejected, payload: n.encoded(), on: .controlInput) }
  p.scheduleDeadline = { [weak self] _ in self?.scheduleDeadline(nil) }
  Self.connectInputs(pencil: pencil, touch: p, zoom: zoom); return p
 }()
 private lazy var sender = VideoSender(diagnostics: diagnostics)
 private var adaptation = VideoAdaptation()
 private var video: MacVideo?
 private var videoGeneration: UInt32 = 0
 private var videoFallback = false, videoConfirmed = false
 private var decoderPressureUntil: UInt64 = 0
 private var videoStartedAt: UInt64 = 0
 private var videoDrawable = CGSize.zero
 public static func savedVideo(_ transport: TransportKind) -> VideoSettings {
  guard let data = UserDefaults.standard.data(forKey: "video." + transport.rawValue), let value = try? JSONDecoder().decode(VideoSettings.self, from: data), value.isValid else { return .baseline }
  return value
 }
 public func restoreSavedVideo(_ transport: TransportKind) {
  guard let data = UserDefaults.standard.data(forKey: "video.saved." + transport.rawValue), let value = try? JSONDecoder().decode(VideoSettings.self, from: data), value.isValid else { return }
  selectVideo(value, transport: transport)
 }
 public func selectVideo(_ settings: VideoSettings, transport: TransportKind) {
  guard settings.isValid else { return }
  let savedKey = "video.saved." + transport.rawValue
  if UserDefaults.standard.data(forKey: savedKey) == nil,
     let existing = try? JSONEncoder().encode(Self.savedVideo(transport)) {
   UserDefaults.standard.set(existing, forKey: savedKey)
  }
  if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "video." + transport.rawValue) }
  ui { if transport == .usb { $0.usbVideo = settings } else { $0.wifiVideo = settings }; $0.videoSettingsNote = "已保存，下次连接生效。可随时选择当前档位恢复。" }
 }
 private func fallbackVideo() {
  guard !videoFallback, let a = attachment, a.isReady else { return }
  videoFallback = true; video?.stop(); sender.reset()
  diagnostics.fault(row: "1", reason: "highQualityFallback", generation: a.generation)
  ui { $0.videoSettingsNote = "高画质未完成解码确认，当前连接已回退原档位。" }
  startVideo(generation: a.generation, drawable: videoDrawable)
 }

 private var videoState = "idle", lastVideoError: String?
 private var tickTimer: DispatchSourceTimer?, deadlineTimer: DispatchSourceTimer?
 private var gate = DialGate(), redialing = false, lastPermissionCheck: UInt64 = 0
 private let targetMonitor = InputTargetMonitor()
 private var targetGuard = InputTargetGuard()
 private var observers: [NSObjectProtocol] = []

 public init() {}

 public func beginDiagnosticSession() {
  var status = SessionDiagnostics(); status.role = "mac"
  status.model = HardwareModel.current; status.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
  status.applyBuild(BuildIdentity.current); diagnostics.updateSession(status)
  do {
   if try diagnostics.beginSessionRecovery() { model.previousSessionNote = "上次运行未正常结束：已保留有限诊断。可能是系统终止、强制退出或异常；请导出诊断，若曾闪退还需系统崩溃报告。" }
  } catch { diagnostics.fault(row: "8", reason: "diagnosticRecoveryUnavailable", generation: 0) }
 }
 public func endDiagnosticSession() { diagnostics.mark("app.normalExit"); diagnostics.finishSessionRecovery() }

 public func start() {
  performanceObserver.start()
  targetMonitor.onChange = { [weak self] revision in
   self?.queue.async {
    guard let self else { return }
    guard self.targetMonitor.currentRevision == revision else { return }
    if let gesture = self.targetGuard.changed(to: revision), self.pencil.ownership.active?.gestureID == gesture { self.pencil.cancelAll(.targetChanged) }
    if let a = self.attachment { Self.targetChanged(to: revision, input: InputContext(a), touch: self.touch) }
   }
  }
  targetMonitor.start()
  queue.async { [self] in
   do {
    let context = try KeychainIdentity.load(); security = context
    context.onChange = { [weak self] in self?.refreshTrustUI() }; refreshTrustUI(); startLANDiscovery()
   } catch { ui { $0.phase = .needsAttention; $0.status = "设备身份无法读取：请退出并重新打开 PadInk；持续失败时请导出诊断" }; return }
   let t = DispatchSource.makeTimerSource(queue: queue); t.schedule(deadline: .now(), repeating: .milliseconds(250))
   t.setEventHandler { [weak self] in self?.tick() }; tickTimer = t; t.resume()
  }
  let center = NSWorkspace.shared.notificationCenter
  observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
   self?.queue.sync { guard let self else { return }; self.gate.sleeping = true; self.attachment?.close(.appBackground) }
  })
  observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in self?.queue.async { self?.gate.woke() } })
  observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
   // The capture raster and the Quartz mapping both depend on the display: start a fresh attachment.
   self?.queue.async { guard let self, let v = self.video else { return }
    if CGMainDisplayID() != v.displayID || CGDisplayBounds(v.displayID) != self.backend.displayBounds { self.diagnostics.mark("session.displayChanged"); self.attachment?.close(.settingsChanged) } }
  })
 }

 public func shutdown() { performanceObserver.stop(); targetMonitor.stop(); queue.sync { lanDiscovery?.stop(); lanPairing?.cancel(); pendingUSB?.control.close(); pendingUSB?.video.close(); attachment?.close(.appQuit); video?.stop() } }
 public func userDisconnect() { queue.async { [self] in session.userDisconnect(); lanPairing?.cancel(); lanPairing = nil; pendingUSB?.control.close(); pendingUSB?.video.close(); pendingUSB = nil; attachment?.close(.userDisconnect); ui { $0.lanPairing = nil; $0.paused = true; $0.phase = .paused; $0.status = "已暂停连接：点“重新连接”恢复" } } }
 public func userResume() { queue.async { [self] in security?.allowNewPairing(); session.userResume(); gate.woke(); ui { $0.paused = false; $0.needsUpdate = nil; $0.phase = .waiting; $0.status = "等待 iPad 连接：请解锁 iPad 并打开 PadInk" } } }

 public func resetZoom() { queue.async { [self] in let t = targetMonitor.zoomTarget; touch.resetZoom(targetRevision: t.revision, target: t.snapshot) } }

 public func requestPermissions() {
  if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
  _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
 }
 public func openPrivacySettings(accessibility: Bool) {
  let pane = accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
  if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
 }
 public func exportDiagnostics() {
  guard !model.exportingDiagnostics else { return }
  model.exportingDiagnostics = true; model.exportURL = nil; model.exportMessage = "正在生成诊断…"
  DispatchQueue.global(qos: .utility).async { [self] in
   let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("\(ProductIdentity.displayName) 诊断")
   let message: String
   do { let url = try diagnostics.export(to: dir); message = "已导出到“文稿 / \(ProductIdentity.displayName) 诊断”：\(url.lastPathComponent)；也请导出 iPad 端诊断"; DispatchQueue.main.async { [model] in model.exportURL = url; NSWorkspace.shared.activateFileViewerSelecting([url]) } }
   catch { message = "导出失败：\(error.localizedDescription)" }
   ui { $0.exportingDiagnostics = false; $0.exportMessage = message }
  }
 }

 public func confirmPairing(_ request: PairingRequest, accepted: Bool) {
  queue.async { [self] in security?.confirm(request.deviceID, accepted: accepted) }
 }
 public func forgetDevice(_ peer: PairingRequest) {
  queue.async { [self] in
   do {
    try security?.forget(peer.deviceID)
    if attachment?.peer?.deviceID == peer.deviceID { session.userDisconnect(); attachment?.close(.forgetDevice); ui { $0.paused = true; $0.phase = .paused; $0.status = "已忘记设备：在 iPad 允许重新配对，再点“重新连接”" } }
   } catch { ui { $0.lastInputNote = "无法保存设备设置，请重试" } }
  }
 }
 private func refreshTrustUI() {
  guard let security else { return }
  let request = security.requests.first, devices = security.store.peers.map { PairingRequest(deviceID: $0.deviceID, name: $0.name) }
  ui { $0.pairing = request; $0.trustedDevices = devices; if request != nil { $0.phase = .needsAttention; $0.status = "请在 Mac 和 iPad 两端确认 USB 配对" } }
 }

 private func startLANDiscovery() {
  let browser = LANDiscovery(queue: queue); lanDiscovery = browser
  browser.onUpdate = { [weak self] peers in
   guard let self else { return }; self.lanPeers = peers
   let listed = peers.map { PairingRequest(deviceID: $0.id, name: $0.name) }
   self.ui { $0.lanDevices = listed }
  }
  browser.onStatus = { [weak self] note in self?.ui { $0.lanNote = note } }; browser.start()
 }
 public func pairWiFi(_ device: PairingRequest) {
  queue.async { [self] in
   guard let security, let peer = lanPeers.first(where: { $0.id == device.deviceID }) else { return }
   if let current = attachment, current.peer?.deviceID != peer.id {
    ui { $0.lanNote = "当前正在连接另一台 iPad；请先点“暂停连接”，再选择这台设备" }; return
   }
   preferredLANPeer = peer.id
   if security.store.peer(peer.id) != nil {
    session.userResume(); gate.woke()
    ui { $0.paused = false; if !$0.connected { $0.phase = .waiting; $0.status = "等待已配对 iPad 连接…" } }
    return
   }
   guard let endpoint = peer.pairingEndpoint else { ui { $0.lanNote = "请先在 iPad 菜单点“Wi-Fi 配对”" }; return }
   lanPairing?.cancel()
   let socket = LANPairingSocket(stream: NWStream(NWConnection(to: endpoint, using: .tcp), queue: queue), identity: security.identity, store: security.store, role: .mac, name: Host.current().localizedName ?? "Mac", queue: queue)
   lanPairing = socket
   socket.onPrompt = { [weak self] prompt in self?.ui { $0.lanPairing = prompt } }
   socket.onComplete = { [weak self, weak socket] success in
    guard let self, self.lanPairing === socket else { return }; self.lanPairing = nil
    self.ui { $0.lanPairing = nil; $0.lanNote = success ? "Wi-Fi 配对已保存" : "Wi-Fi 配对未完成，请重试" }
    if success { security.onChange?(); self.session.userResume(); self.gate.woke(); self.ui { $0.paused = false } }
   }; socket.start()
  }
 }
 public func confirmWiFiPairing(_ accepted: Bool) { queue.async { [self] in lanPairing?.confirm(accepted) } }
 private func connectLAN() {
  guard attachment == nil, gate.permissionsGranted, !gate.sleeping, let security,
        let peer = lanPeers.first(where: { security.store.peer($0.id) != nil && (preferredLANPeer == nil || $0.id == preferredLANPeer) }), let trust = security.store.peer(peer.id) else { return }
  do {
   let a = try LANTLS.stream(to: peer.endpoint, local: security.identity.id, peer: trust, queue: queue)
   let b = try LANTLS.stream(to: peer.endpoint, local: security.identity.id, peer: trust, queue: queue)
   guard let g = session.beginAttachment() else { a.close(); b.close(); return }
   activeLANPeer = peer; attach(generation: g, device: nil, control: a, video: b, transport: .wifi, expectedPeer: peer.id)
  } catch { ui { $0.lanNote = "Wi-Fi 安全连接无法建立，请使用 USB 或重新配对" } }
 }
 private func checkUSBPriority(now: UInt64) {
  guard let current = attachment, current.transport == .wifi, current.isReady, gate.permissionsGranted, !gate.sleeping else { return }
  if pendingUSB == nil, !usbChecking, now >= lastUSBCheck, now - lastUSBCheck >= 1_000_000_000 {
   lastUSBCheck = now; usbChecking = true; usbDialAttempts &+= 1
   discovery.async { [weak self] in
    let result = USBDialer.dialResult()
    guard let self else { result.connection?.control.close(); result.connection?.video.close(); return }
    self.queue.async { [weak self] in
     guard let self else { result.connection?.control.close(); result.connection?.video.close(); return }
     self.usbChecking = false
     guard self.attachment === current, self.gate.permissionsGranted, !self.gate.sleeping else {
      result.connection?.control.close(); result.connection?.video.close(); return
     }
     self.recordUSB(result); self.pendingUSB = result.connection
    }
   }
  }
  let action = selection.decide(current: .wifi, usbAvailable: pendingUSB != nil, lanAvailable: true,
    inputActive: pencil.ownership.active != nil || touch.ownership.active != nil, paused: session.state == .paused, now: now)
  guard action != .stay, let result = pendingUSB else { return }; pendingUSB = nil
  let peerID = current.peer?.deviceID
  pencil.cancelAll(.transportLost); touch.cancel(.transportLost); current.close(.settingsChanged)
  guard let g = session.beginAttachment() else { result.control.close(); result.video.close(); return }
  attach(generation: g, device: result.device, control: result.control, video: result.video, expectedPeer: peerID)
 }

 /// Preserve only bounded dial facts, never the result's streams or a device serial.
 private func recordUSB(_ result: USBDialer.DialResult) {
  let reason = result.stage == .connected || result.stage == .noUSB ? nil : result.reasonCode
  if usbDialStage != result.stage || usbDialError != reason || usbDeviceCount != result.deviceCount {
   diagnostics.mark("usb.dial", state: result.stage.rawValue + (reason.map { ":" + $0 } ?? ""), value: result.deviceCount.map(Double.init))
  }
  usbDialStage = result.stage; usbDialError = reason; usbDeviceCount = result.deviceCount
  refreshUSBNote()
 }
 private func refreshUSBNote() {
  let note = Self.usbNote(stage: usbDialStage, reason: usbDialError, attachmentError: usbAttachmentError,
                          activeUSB: attachment?.transport == .usb && attachment?.isReady == true)
  ui { if $0.usbNote != note { $0.usbNote = note } }
 }
 static func usbNote(stage: USBDialer.Stage?, reason: String? = nil, attachmentError: String?, activeUSB: Bool) -> String? {
  guard !activeUSB else { return nil }
  switch stage {
  case .enumeration: return "无法查询 USB 设备，正在重试；可继续使用 Wi-Fi"
  case .controlConnect, .videoConnect:
   if reason?.hasPrefix("refused_") == true { return "已检测到 USB 设备，但 iPad 的 USB 连接服务尚未就绪；正在重试，可继续使用 Wi-Fi" }
   return "USB 连接暂不可用，正在重试；可继续使用 Wi-Fi，详情可导出诊断"
  case .connected where attachmentError != nil: return "USB 连接未完成，正在重试；可继续使用 Wi-Fi"
  default: return nil
  }
 }

 // MARK: Timer

 private func tick() {
  let now = MonotonicClock.now
  guard security != nil else { return }
  if now &- lastPermissionCheck >= 1_000_000_000 || lastPermissionCheck == 0 {
   lastPermissionCheck = now
   let previouslyGranted = gate.permissionsGranted
   let screen = CGPreflightScreenCaptureAccess(), access = AXIsProcessTrusted(); gate.permissionsGranted = screen && access
   ui {
    if $0.screenRecordingGranted != screen { $0.screenRecordingGranted = screen }
    if $0.accessibilityGranted != access { $0.accessibilityGranted = access }
    if !(screen && access) { $0.phase = .needsAttention; $0.status = screen ? "缺少辅助功能权限：请在系统设置允许 PadInk 操作 Mac" : "缺少屏幕录制权限：请在系统设置允许 PadInk 显示 Mac 画面，随后退出并重开" }
    else if !previouslyGranted && !$0.connected && !$0.paused { $0.phase = .waiting; $0.status = "权限已就绪，等待 iPad 连接" }
   }
   if !gate.permissionsGranted, let a = attachment { diagnostics.mark("permission.missing"); a.close(.settingsChanged) }
  }
  attachment?.tick(); checkUSBPriority(now: now)
  if let video, video.settings != .baseline, !videoConfirmed, now >= videoStartedAt, now - videoStartedAt > 8_000_000_000 { fallbackVideo() }
  if let a = attachment, a.isReady {
   let sendPressure = sender.takeCongestion(now: now)
   let congested = a.health != .healthy || sendPressure || now < decoderPressureUntil
   if let profile = adaptation.update(congested: congested, now: now), !(performanceWindow.active && PerformanceExperiment.mode == .lowVideo) {
    video?.setProfile(profile)
    diagnostics.fault(row: "1", reason: profile.quality.rawValue, generation: a.generation)
   }
  }
  var status = SessionDiagnostics(); status.role = "mac"; status.transport = attachment?.transport.rawValue ?? "none"
  status.connection = attachment?.isReady == true ? "active" : "waiting"; status.generation = attachment?.generation ?? 0; status.reconnects = session.reconnects
  status.peerID = attachment?.peer?.deviceID.prefix(6).map { String(format: "%02x", $0) }.joined()
  status.peerAppVersion = attachment?.peer?.appVersion; status.signingExpiry = attachment?.peer?.signingExpiry
  status.rttMilliseconds = attachment?.controlRTT.map { Double($0) / 1e6 }; status.clock = attachment?.clockEstimate
  status.inputOwner = pencil.ownership.active != nil ? "pencil" : touch.ownership.active != nil ? "touch" : "none"; status.gesture = pencil.ownership.active?.gestureID ?? touch.ownership.active?.gestureID
  status.applicationStrategy = applicationStrategy
  status.queuedVideoBytes = attachment?.queuedBytes(on: .video) ?? 0
  status.videoProfile = adaptation.profile.quality.rawValue
  if let video { status.bitrate = video.targetBitrate }
  status.model = HardwareModel.current; status.operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString; status.appVersion = Self.appVersion
  status.sourceBuild = BuildIdentity.current.source; status.videoState = videoState; status.lastVideoError = lastVideoError
  status.usbDialStage = usbDialStage?.rawValue; status.usbDialError = usbDialError
  status.usbDeviceCount = usbDeviceCount; status.usbDialAttempts = usbDialAttempts; status.usbAttachmentError = usbAttachmentError
  status.applyBuild(BuildIdentity.current)
  diagnostics.updateSession(status)
  diagnostics.checkpointSessionRecovery()
  guard gate.shouldDial(now: now, attached: attachment != nil, session: session) else { return }
  gate.attempted(now: now)
  usbDialAttempts &+= 1
  discovery.async { [weak self] in
   let result = USBDialer.dialResult()
   guard let self else { result.connection?.control.close(); result.connection?.video.close(); return }
   self.queue.async { [weak self] in
    guard let self else { result.connection?.control.close(); result.connection?.video.close(); return }
    self.gate.finishedAttempt()
    guard self.gate.permissionsGranted, !self.gate.sleeping else { result.connection?.control.close(); result.connection?.video.close(); return }
    guard self.attachment == nil else { result.connection?.control.close(); result.connection?.video.close(); return }
    self.recordUSB(result)
    guard let r = result.connection else { self.connectLAN(); return }
    guard let g = self.session.beginAttachment() else { r.control.close(); r.video.close(); return }
    self.attach(generation: g, device: r.device, control: r.control, video: r.video)
   }
  }
 }

 // MARK: Attachment

 private func localIdentity() -> LocalIdentity {
  LocalIdentity(appVersion: BuildIdentity.current.wireVersion, deviceID: security!.identity.id, displayName: Host.current().localizedName ?? "Mac", capabilities: [.extendedVideo])
 }
 static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0-dev" }

 private func attach(generation g: UInt32, device: USBMux.Device?, control: ByteStream, video: ByteStream, transport: TransportKind = .usb, expectedPeer: Data? = nil) {
  guard let security else { control.close(); video.close(); return }
  self.device = device
  let a = Attachment(role: .mac, attachmentID: UUID(), generation: g, resumeToken: session.resumeToken, local: localIdentity(), security: security, transport: transport, expectedPeerID: expectedPeer, trustedOnly: transport == .wifi, queue: queue)
  performanceWindow.reset(); performanceVideoStopped = false
  attachment = a; a.performance = diagnostics.performance
  a.onEvent = { [weak self, weak a] event in guard let self, let a, self.attachment === a else { return }; self.handle(event, a) }
  diagnostics.mark("session.attaching", session: UInt64(g), state: transport.rawValue)
  let name = transport == .usb ? "USB" : "Wi-Fi"
  ui { $0.phase = .connecting; $0.transport = name; $0.transportNotice = nil; $0.status = "正在通过 \(name) 连接 iPad…" }
  a.start(control: control, video: video)
 }

 private func handle(_ event: AttachmentEvent, _ a: Attachment) {
  let g = a.generation
  Self.inputAttachmentEvent(event, input: InputContext(a), pencil: pencil, touch: touch)
  switch event {
  case .ready(let peer):
   a.recordPerformanceRoutes()
   lanFailures = 0; ui { $0.lanNote = nil }
   videoFallback = false; videoGeneration = 0
   session.attachmentReady(generation: g)
   startVideo(generation: g, drawable: CGSize(width: Int(peer.drawableWidth), height: Int(peer.drawableHeight)))
   diagnostics.mark("session.ready", session: UInt64(g), state: "peerVersion=\(peer.appVersion)")
   if a.transport == .usb { usbAttachmentError = nil }; refreshUSBNote()
   let connectionName = a.transport == .usb ? "USB" : "Wi-Fi"
   let warning = BuildIdentity.current.isDeveloperInstall ? Self.signingWarning(expiry: peer.signingExpiry) : nil
   let notice = transportPresentation.confirmed(a.transport, peer: peer.deviceID)
   ui { $0.connected = true; $0.paused = false; $0.peerVersion = peer.appVersion; $0.peerName = peer.displayName; $0.transport = connectionName; $0.phase = .waitingForVideo; $0.status = "已连接 · \(connectionName)，等待 iPad 显示画面…"; $0.transportNotice = notice; $0.signingWarning = warning; $0.lastInputNote = nil }
   if notice != nil { clearTransportNotice(after: a) }
  case .frame(.controlInput, let f, let stamp):
   handleInput(f, stamp: stamp, a)
   if ConnectionPresentation.confirmsVideo(f), attachment === a, a.ended == nil, videoState != "failed", videoState != "presenting" {
    videoState = "presenting"
    let context = InputContext(a)
    performanceWindow.arm(context, diagnostics: diagnostics, queue: queue, isCurrent: { [weak self, weak a] in
     guard let a else { return false }; return self?.attachment === a && a.ended == nil
    }, begin: { [weak self] in
     guard let self else { return }
     if PerformanceExperiment.mode == .noVideo {
      self.performanceVideoStopped = true; self.video?.stop(); self.sender.reset()
     } else if PerformanceExperiment.mode == .lowVideo {
      self.video?.setProfile(VideoProfile(.reducedFrameRate, transport: a.transport))
     }
    })
    ui { $0.phase = .active; $0.status = "已连接 · \(a.transport == .usb ? "USB" : "Wi-Fi")"; $0.videoNote = nil }
   }
  case .frame(.video, let f, _):
   if f.type == .keyframeRequest { video?.requestKeyframe() }
   if f.type == .videoFeedback, let ack = try? VideoFeedback(f.payload), let video,
      ack.generation <= videoGeneration, ack.codec == video.settings.codec,
      Int(ack.width) == Int(video.raster.width), Int(ack.height) == Int(video.raster.height) {
    if ack.congested { decoderPressureUntil = MonotonicClock.now + 1_500_000_000 }
    guard ack.generation == videoGeneration, !videoConfirmed else { break }
    videoConfirmed = true
    diagnostics.mark("video.hardwareDecodeConfirmed", session: UInt64(g), item: UInt64(ack.generation))
    ui { $0.videoSettingsNote = "iPad 已实际硬件解码当前配置；画质与稳定性仍以实测为准。" }
   }
  case .health(let h):
   diagnostics.mark("session.health", session: UInt64(g), state: String(describing: h))
   let connectionName = a.transport == .usb ? "USB" : "Wi-Fi"
   if case .videoCongested = h { diagnostics.fault(row: "1", reason: "videoCongested", generation: g); ui { $0.status = "已连接 · \(connectionName)（画面降级中）" } } else if case .healthy = h, videoState == "presenting" { ui { $0.phase = .active; $0.status = "已连接 · \(connectionName)" } }
  case .videoRebuildNeeded(let reason):
   diagnostics.fault(row: "7b", reason: String(describing: reason), generation: g)
   diagnostics.mark("video.rebuild", session: UInt64(g), state: String(describing: reason))
   videoState = "recovering"; ui { $0.phase = .recovering; $0.status = "已连接 · \(a.transport == .usb ? "USB" : "Wi-Fi")，画面恢复中"; $0.videoNote = "画面连接中断，正在恢复；输入连接仍在。持续无画面时请导出双端诊断" }
   sender.reset(); redialVideo(a)
  case .videoRebuilt:
   video?.requestKeyframe()
  case .ended(let end):
   if a.transport == .usb {
    switch end {
    case .closedLocally, .peerGoodbye, .replaced: break
    default: usbAttachmentError = end.diagnosticFault.reason
    }
    diagnostics.mark("usb.attachmentEnded", session: UInt64(g), state: end.diagnosticFault.reason)
   }
   if a.transport == .wifi { lanFailures += 1; if lanFailures >= 3 { ui { $0.lanNote = "Wi-Fi 无法连接。当前网络可能不允许设备互连，请使用 USB；也可检查两端本地网络权限或重新配对。" } } }
   diagnostics.fault(row: end.diagnosticFault.row, reason: end.diagnosticFault.reason, generation: UInt32(g))
   diagnostics.mark("session.ended", session: UInt64(g), state: String(describing: end))
   pendingUSB?.control.close(); pendingUSB?.video.close(); pendingUSB = nil
   video?.stop(); video = nil; sender.reset(); attachment = nil; redialing = false
   refreshUSBNote()
   if videoState != "failed" { videoState = "idle"; ui { $0.videoNote = nil } }
   _ = session.attachmentEnded(generation: g, end)
   let note = Self.describe(end), update: String? = { if case .needsUpdate(let n) = session.state { return n == .updatePeer ? "iPad 上的 PadInk 版本过旧，请更新 iPad 端" : "这台 Mac 上的 PadInk 版本过旧，请更新 Mac 端" }; return nil }()
   let paused = session.state == .paused
   let presentation = ConnectionPresentation.ended(end, peer: "iPad")
   let failedVideo = videoState == "failed"
   let permissions = gate.permissionsGranted
   ui { $0.paused = paused; $0.connected = false; $0.raster = ""; $0.peerName = ""; $0.transportNotice = nil; $0.phase = failedVideo || !permissions ? .needsAttention : presentation.phase; $0.status = failedVideo ? "画面启动失败：请查看下方原因" : note; $0.needsUpdate = update }
  default: break
  }
 }

 private func handleInput(_ f: Frame, stamp: ReceiveStamp, _ a: Attachment) {
  let now = MonotonicClock.now
  do {
   let target = targetMonitor.zoomTarget
   try Self.receiveInput(f, stamp: stamp, now: now, input: InputContext(a), targetRevision: target.revision, target: target.snapshot, pencil: pencil, touch: touch)
   if f.type == .pencil, let id = pencil.ownership.active?.gestureID, targetGuard.contact?.gesture != id { targetGuard.began(id, revision: target.revision) }
   if pencil.ownership.active == nil { targetGuard.ended() }
  } catch { a.abort(protocolViolation: "payload \(f.type.rawValue): \(error)") }
 }

 /// These are the product's actual reception/lifecycle entry points. Tests use the same functions
 /// with real pipelines and no-side-effect backends, without starting discovery or taking input.
 static func connectInputs(pencil: PencilInputPipeline, touch: TouchInputPipeline, zoom: ZoomController) {
  touch.connectZoom(zoom)
  pencil.onAcceptedBegin = { [weak touch] in touch?.pencilTakeover() }
 }
 static func inputAttachmentEvent(_ event: AttachmentEvent, input: InputContext, pencil: PencilInputPipeline, touch: TouchInputPipeline) {
  switch event {
  case .ready: pencil.attach(generation: UInt64(input.generation)); touch.attach(context: input)
  case .ended:
   guard touch.inputMatches(input) else { return }
   pencil.detach(); touch.disconnect(input: input)
  default: break // B-only recovery and health changes have no control-input invalidation.
  }
 }
 static func targetChanged(to revision: UInt64, input: InputContext, touch: TouchInputPipeline) { touch.targetChanged(to: revision, input: input) }
 static func receiveInput(_ f: Frame, stamp: ReceiveStamp, now: UInt64, input: InputContext, targetRevision: UInt64, target: ZoomTargetSnapshot?, pencil: PencilInputPipeline, touch: TouchInputPipeline) throws {
  guard touch.inputMatches(input) else { return }
  switch f.type {
  case .pencil: pencil.pencil(try PencilBatch(f.payload), stamp: stamp, now: now)
  case .pointer, .scroll, .magnify:
   touch.receive(try TouchEvent(f.payload, type: f.type), stamp: stamp, now: now, pencilActive: pencil.ownership.active != nil, input: input, targetRevision: targetRevision, target: target)
  case .inputSettings: touch.setEnabled(try InputSettings(f.payload).touchEnabled)
  case .gestureKeepalive:
   let k = try GestureKeepalive(f.payload)
   if k.gestureID & (1 << 63) != 0 { touch.keepalive(k, stamp: stamp, now: now) } else { pencil.keepalive(k, stamp: stamp, now: now) }
  case .inputCancel:
   let n = try GestureNotice(f.payload)
   touch.cancelFromPeer(n, input: input); pencil.cancelFromPeer(n)
  case .presentedGeometry:
   let g = try PresentedGeometry(f.payload); pencil.presentedGeometry(g); touch.geometry(g, input: input)
  default: break
  }
 }

 /// One-shot timer at the active gesture's deadline (fault row 6): releases a stationary pencil
 /// whose keepalives stopped, even if no message ever arrives again.
 private func scheduleDeadline(_ deadline: UInt64?) {
  deadlineTimer?.cancel(); deadlineTimer = nil
  guard let deadline = [pencil.ownership.nextDeadline, touch.ownership.deadline].compactMap({ $0 }).min() else { return }
  let t = DispatchSource.makeTimerSource(queue: queue)
  t.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
  t.setEventHandler { [weak self] in let now = MonotonicClock.now; self?.pencil.timer(now: now); self?.touch.timer(now: now) }
  deadlineTimer = t; t.resume()
 }

 private func redialVideo(_ a: Attachment) {
  if a.transport == .wifi {
   guard let security, let id = a.peer?.deviceID, let trust = security.store.peer(id), let peer = lanPeers.first(where: { $0.id == id }) ?? activeLANPeer else { a.videoRebuildFailed(); return }
   do { a.replaceVideo(try LANTLS.stream(to: peer.endpoint, local: security.identity.id, peer: trust, queue: queue)) } catch { a.videoRebuildFailed() }; return
  }
  guard !redialing, let device else { return }
  redialing = true
  discovery.async { [weak self] in
   let stream = USBDialer.redialVideo(device: device)
   self?.queue.async { guard let self else { stream?.close(); return }; self.redialing = false
    guard self.attachment === a, a.ended == nil else { stream?.close(); return }
    guard let stream else { self.diagnostics.mark("video.redialFailed"); a.videoRebuildFailed(); return }
    a.replaceVideo(stream) }
  }
 }

 // MARK: Video

 private func startVideo(generation g: UInt32, drawable: CGSize) {
  decoderPressureUntil = 0
  videoDrawable = drawable; videoConfirmed = false; videoStartedAt = MonotonicClock.now
  adaptation = VideoAdaptation(transport: attachment?.transport ?? .usb)
  var settings = videoFallback ? VideoSettings.baseline : Self.savedVideo(attachment?.transport ?? .usb)
  let extended = attachment?.peer?.capabilities.contains(.extendedVideo) == true
  if !extended { settings = .baseline }
  videoState = "starting"; ui { $0.videoNote = "已连接，正在准备画面…" }
  let display = CGMainDisplayID()
  backend.displayBounds = CGDisplayBounds(display); pointerBackend.displayBounds = backend.displayBounds
  diagnostics.mark("input.macGeometry", session: UInt64(g), state: "display=\(display); bounds=\(backend.displayBounds); Quartz global logical points")
  let v = MacVideo(session: UInt64(g), diagnostics: diagnostics, displayID: display, settings: settings, extended: extended, generationSeed: videoGeneration); video = v
  v.setProfile(adaptation.profile)
  let sender = self.sender
  sender.reset()
  sender.send = { [weak self] type, payload, flags, completion in
   guard let self, !self.performanceVideoStopped else { return false }
   return self.attachment?.send(type, payload: payload, flags: flags, on: .video, completion: completion) ?? false
  }
  sender.requestKeyframe = { [weak v] in v?.requestKeyframe() }
  sender.onBacklogCleared = { [weak v] in v?.backlogCleared() }
  v.shouldSkip = { sender.isBacklogged }
  Self.connectVideo(v, queue: queue, isCurrent: { [weak self] in self?.video === $0 },
   onFrame: { [weak self] config, frame in
    guard let self, !self.performanceVideoStopped else { return }; if let config { self.videoGeneration = config.generation }; self.sender.push(config, frame)
    if self.videoState == "starting" || self.videoState == "recovering" { self.videoState = "sending"; self.ui { $0.videoNote = "正在发送画面，等待 iPad 显示确认…" } }
   },
   onError: { [weak self] error in
    guard let self else { return }
    if self.video?.settings != .baseline, !self.videoFallback { self.fallbackVideo(); return }
    let failure = Self.describeVideoFailure(error, screenRecordingGranted: CGPreflightScreenCaptureAccess())
    self.videoState = "failed"; self.lastVideoError = failure.code
    self.diagnostics.mark("video.error", session: UInt64(g), state: failure.code)
    self.diagnostics.fault(row: "1", reason: failure.code, generation: g)
    self.ui { $0.phase = .needsAttention; $0.videoNote = failure.message }
    self.attachment?.close(.settingsChanged)
   })
  let size = drawable.width > 0 ? drawable : CGSize(width: 2732, height: 2048)
  Task { [weak self] in
   do {
    try await v.start(drawable: size)
    self?.queue.async { [weak self, weak v] in guard let self, let v, self.video === v else { return }; let r = v.raster; self.ui { $0.raster = "\(Int(r.width)) × \(Int(r.height))" } }
   } catch { v.reportError(error) }
  }
 }

 /// Neither stored callbacks nor callbacks already waiting on the coordinator queue own a video.
 /// Recheck current identity at execution, not just when the frame/error arrives.
 static func connectVideo(_ video: MacVideo, queue: DispatchQueue, isCurrent: @escaping (MacVideo) -> Bool,
                          onFrame: @escaping (VideoConfig?, VideoFrame) -> Void, onError: @escaping (Error) -> Void) {
  video.onFrame = { [weak video] config, frame in
   let enqueued = MonotonicClock.now
   queue.async { [weak video] in guard let video, isCurrent(video) else { return }; video.recordSendQueue(enqueued, frame: frame.id); onFrame(config, frame) }
  }
  video.onError = { [weak video] error in
   queue.async { [weak video] in guard let video, isCurrent(video) else { return }; onError(error) }
  }
 }

 // MARK: Helpers

 private func ui(_ change: @escaping (MacModel) -> Void) { DispatchQueue.main.async { [model] in change(model) } }

 static func describeVideoFailure(_ error: Error, screenRecordingGranted: Bool) -> (code: String, message: String) {
  if !screenRecordingGranted { return ("screenRecordingDenied", "无法采集画面：请在系统设置授权屏幕录制，然后重新打开 PadInk") }
  if let error = error as? VideoPipelineError {
   switch error {
   case .hardware: return ("hardwareEncoderUnavailable", "硬件视频编码不可用，正在重试；持续失败时请导出诊断")
   case .codec(let code): return ("encoderFailure", "视频编码失败（\(code)），正在重试；持续失败时请导出诊断")
   case .frameTooLarge: return ("encodedFrameTooLarge", "画面编码超出传输上限，正在重试；持续失败时请导出诊断")
   case .capture: break
   }
  }
  return ("captureFailure", "屏幕采集已中断，正在重试；持续失败时请导出诊断")
 }
 static func signingWarning(expiry: UInt64, now: Date = Date()) -> String? {
  guard expiry > 0 else { return nil }
  let remaining = TimeInterval(expiry) - now.timeIntervalSince1970
  guard remaining < 3 * 86_400 else { return nil }
  return remaining <= 0 ? "iPad 上的 PadInk 签名已过期。请插上 iPad，双击“更新 PadInk”。" : "iPad 上的 PadInk 将在 \(max(1, Int(ceil(remaining / 86_400)))) 天内过期。请插上 iPad，双击“更新 PadInk”。"
 }
 static func describe(_ end: AttachmentEnd) -> String { ConnectionPresentation.ended(end, peer: "iPad").message }
 private func clearTransportNotice(after a: Attachment) {
  queue.asyncAfter(deadline: .now() + 8) { [weak self, weak a] in
   guard let self, let a, self.attachment === a else { return }; self.ui { $0.transportNotice = nil }
  }
 }
 static func describe(_ reason: CancelReason) -> String {
  switch reason {
  case .geometryMismatch: return "画面尺寸刚刚变化，这一笔未写入，请重新落笔"
  case .staleSample, .gestureTimeout: return "这一笔延迟过大已安全结束，请重新落笔"
  case .targetChanged: return "前台应用切换，已安全结束当前笔画"
  default: return "已安全结束当前笔画"
  }
 }
}
#endif
