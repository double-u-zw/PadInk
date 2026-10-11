#if os(macOS)
import AppKit
import PadInkCore

/// Public mouse and pixel-scroll events only. Never adds tablet fields or undocumented magnify.
public final class PointerInjectionBackend {
 public var displayBounds = CGRect.zero
 public private(set) var pressed = false
 var nativeScroll: (TouchEvent) throws -> Bool = { _ in false }
 var resetMagnify: () -> Void = {}
 public var magnify: (TouchEvent) throws -> Void = { _ in }
 private let source = CGEventSource(stateID: .hidSystemState), post: (CGEvent) -> Void
 private var location = CGPoint.zero, clickCount: Int64 = 1, scrolling = false
 private var residualX = 0.0, residualY = 0.0
 public init(postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) { post = postEvent }
 public func deliver(_ event: TouchEvent) throws {
  if event.phase == .cancelled { reset(); if event.kind == .magnify { try magnify(event) }; return }
  let point = VideoGeometry.macPoint(normalized: CGPoint(x: Double(event.x), y: Double(event.y)), captureBounds: displayBounds)
  switch event.kind {
  case .pointer:
   let type: CGEventType
   switch event.phase { case .began: type = .leftMouseDown; case .changed: type = .leftMouseDragged; case .ended, .cancelled: type = .leftMouseUp }
   guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { throw PayloadError.value }
   e.setIntegerValueField(.mouseEventClickState, value: Int64(event.clickCount)); post(e)
   pressed = event.phase == .began || event.phase == .changed; location = point; clickCount = Int64(event.clickCount)
  case .scroll:
   if try nativeScroll(event) { return }
   let phase: Int64
   switch event.phase { case .began: phase = 1; case .changed: phase = 2; case .ended: phase = 4; case .cancelled: phase = 8 }
   // A trackpad scroll targets the pointer's original location; finger travel
   // changes the delta, not the receiving view under the pointer.
   let anchor = event.phase == .began ? point : location
   try scroll(dx: -Double(event.dx) * displayBounds.width, dy: -Double(event.dy) * displayBounds.height, phase: phase, point: anchor)
   scrolling = event.phase == .began || event.phase == .changed; location = anchor
  case .magnify: try magnify(event)
  }
 }
 public func reset() {
  resetMagnify()
  if pressed, let e = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left) { e.setIntegerValueField(.mouseEventClickState, value: clickCount); post(e) }
  if scrolling { try? scroll(dx: 0, dy: 0, phase: 8, point: location) }
  pressed = false; scrolling = false; residualX = 0; residualY = 0
 }
 private func scroll(dx: Double, dy: Double, phase: Int64, point: CGPoint) throws {
  if phase == 1 || phase == 8 { residualX = 0; residualY = 0 }
  if phase != 8 { residualX += dx; residualY += dy }
  let x = residualX.rounded(phase == 4 ? .toNearestOrAwayFromZero : .towardZero)
  let y = residualY.rounded(phase == 4 ? .toNearestOrAwayFromZero : .towardZero)
  guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else { throw PayloadError.value }
  residualX -= x; residualY -= y
  if phase == 4 || phase == 8 { residualX = 0; residualY = 0 }
  e.location = point; e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
  e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
  // Point-delta fields are integers. The constructor sets them consistently with AppKit.
  postOrdinaryScroll(e)
 }
 /// Final post boundary for ordinary scroll, including reset/cancel terminals.
 func postOrdinaryScroll(_ event: CGEvent) {
  // Ordinary scroll has no keyboard-modifier semantics; HID state may carry zoom flags.
  event.flags = []
  post(event)
 }
}

public final class TouchInputPipeline {
 public private(set) var ownership = TouchOwnership()
 public let backend: PointerInjectionBackend
 public var sendReject: (GestureNotice) -> Void = { _ in }
 public var scheduleDeadline: (UInt64?) -> Void = { _ in }
 private let diagnostics: Diagnostics
 private let ecruZoom = EcruNativeZoom()
 private var zoom: ZoomController?, inputContext: InputContext?, contactContext: ZoomActionContext?
 private var receptionRevision: UInt64 = 0, receptionTarget: ZoomTargetSnapshot?
 /// Semantic cancellation is explicit; backend.reset only releases actual physical state.
 func connectZoom(_ controller: ZoomController) {
  zoom = controller
  backend.resetMagnify = { [weak self] in self?.ecruZoom.cancel() }
  backend.nativeScroll = { [weak self] event in
   guard let self, let context = self.contactContext, context.target?.family == .ecru else { return false }
   try self.ecruZoom.receive(event, context: context, bounds: self.backend.displayBounds)
   return true
  }
  backend.magnify = { [weak self] event in
   guard let self, let context = self.contactContext else { return }
   if context.target?.family == .ecru {
    try self.ecruZoom.receive(event, context: context, bounds: self.backend.displayBounds)
    if event.phase == .began { controller.onStrategy("ecruNativePDF"); controller.onStatus("已启用 Ecru 原生连续缩放") }
   } else { controller.receive(event, context: context) }
  }
 }
 func attach(context: InputContext) {
  if let old = inputContext { zoom?.invalidate(input: old) }
  attach(generation: context.generation); inputContext = context
 }
 func inputMatches(_ input: InputContext) -> Bool { inputContext == input }
 func disconnect(input: InputContext) {
  guard inputContext == input else { return }
  cancel(.transportLost); attach()
 }
 func receive(_ e: TouchEvent, stamp: ReceiveStamp, now: UInt64, pencilActive: Bool, input: InputContext, targetRevision: UInt64, target: ZoomTargetSnapshot?) {
  guard inputContext == input else { return }
  receptionRevision = targetRevision; receptionTarget = target
  receive(e, stamp: stamp, now: now, pencilActive: pencilActive)
 }
 func cancelFromPeer(_ notice: GestureNotice, input: InputContext) {
  guard inputContext == input else { return }
  zoom?.invalidate(input: input, gestureID: notice.gestureID)
  if ownership.active?.gestureID == notice.gestureID { execute(ownership.cancel(notice.reason)); backend.reset() }
 }
 func geometry(_ next: PresentedGeometry, input: InputContext) { guard inputContext == input else { return }; geometry(next) }
 func targetChanged(to revision: UInt64, input: InputContext) {
  guard inputContext == input else { return }
  zoom?.targetChanged(to: revision, input: input)
  if let c = contactContext, c.targetRevision < revision { execute(ownership.cancel(.targetChanged)); backend.reset() }
 }
 func pencilTakeover() {
  if let inputContext { zoom?.invalidate(input: inputContext) }
  execute(ownership.cancel(.pencilPreempted)); backend.reset()
 }
 func resetZoom(targetRevision: UInt64, target: ZoomTargetSnapshot?) {
  guard let inputContext, let g = ownership.geometry, g.ready else { return }
  zoom?.resetZoom(context: ZoomActionContext(input: inputContext, gestureID: nil, geometryGeneration: g.generation, targetRevision: targetRevision, target: target))
 }
 public init(backend: PointerInjectionBackend, diagnostics: Diagnostics) { self.backend = backend; self.diagnostics = diagnostics }
 public private(set) var generation: UInt32 = 0
 public func attach(generation: UInt32 = 0) { if let inputContext { zoom?.invalidate(input: inputContext) }; backend.reset(); ownership = TouchOwnership(); self.generation = generation; inputContext = nil; contactContext = nil }
 public func setEnabled(_ enabled: Bool) {
  if ownership.enabled != enabled, !enabled {
   if let inputContext { zoom?.invalidate(input: inputContext, touchOnly: true) }
   execute(ownership.cancel(.settingsChanged)); backend.reset()
  }
  ownership.enabled = enabled
 }
 public func geometry(_ g: PresentedGeometry) { if let inputContext { zoom?.geometry(g, input: inputContext) }; execute(ownership.updateGeometry(g)) }
 public func receive(_ e: TouchEvent, stamp: ReceiveStamp, now: UInt64, pencilActive: Bool) {
  diagnostics.mark("touch.receive", session: UInt64(generation), item: e.gestureID, sequence: UInt64(e.sequence), time: now, state: String(describing: e.kind) + ":" + String(describing: e.phase), value: now >= stamp.localTime ? Double(now - stamp.localTime) / 1e6 : nil)
  execute(ownership.receive(e, stamp: stamp, now: now, pencilActive: pencilActive))
 }
 public func keepalive(_ k: GestureKeepalive, stamp: ReceiveStamp, now: UInt64) { execute(ownership.keepalive(k, stamp: stamp, now: now)) }
 public func timer(now: UInt64) { execute(ownership.timer(now: now)) }
 public func cancel(_ reason: CancelReason) { if let inputContext { zoom?.invalidate(input: inputContext) }; execute(ownership.cancel(reason)); backend.reset() }
 private func execute(_ commands: [TouchOwnership.Command]) {
  for command in commands {
   switch command {
   case .inject(let event):
    // This branch is AFTER ownership admission. Rejected/raw began cannot kill an ended tail.
    if event.phase == .began, let inputContext {
     zoom?.invalidate(input: inputContext)
     contactContext = ZoomActionContext(input: inputContext, gestureID: event.gestureID, geometryGeneration: event.geometryGeneration, targetRevision: receptionRevision, target: receptionTarget)
    }
    do { try backend.deliver(event); ownership.delivered(event)
     if event.phase == .ended || event.phase == .cancelled { contactContext = nil }
     diagnostics.mark("touch.inject", session: UInt64(generation), item: event.gestureID, sequence: UInt64(event.sequence), state: String(describing: event.kind) + ":" + String(describing: event.phase), value: Double(event.dx)) }
    catch { if let contactContext { zoom?.cancel(context: contactContext) }; backend.reset(); execute(ownership.cancel(.protocolViolation)) }
   case .release(let reason):
    if let contactContext { zoom?.cancel(context: contactContext) }; contactContext = nil
    backend.reset(); if let row = reason.diagnosticFaultRow { diagnostics.fault(row: row, reason: String(describing: reason), generation: generation) }
   case .reject(let notice): sendReject(notice)
   }
  }
  if ownership.active == nil, backend.pressed { backend.reset() }
  scheduleDeadline(ownership.deadline)
 }
}
#endif
