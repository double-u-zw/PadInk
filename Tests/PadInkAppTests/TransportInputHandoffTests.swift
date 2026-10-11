import XCTest
import AppKit
@testable import PadInkCore
@testable import PadInkMacKit

/// Authenticated attachments carry real wire messages into the Coordinator's production
/// ownership/backend/zoom path. FakeStream replaces cable/TLS delivery; event sinks replace
/// WindowServer and AX actions. Discovery and physical Pencil capture are outside this seam.
final class TransportInputHandoffTests: XCTestCase {
 private final class ZoomSink: ApplicationZoomContext {
  let family = ApplicationFamily.goodnotes
  var capabilities = ApplicationCapabilities(), calls: [ZoomActionContext] = []
  func execute(_ command: ZoomCommand, permit: ZoomPermit) throws {
   let event = try GoodnotesPublicZoom.event(command, at: CGPoint(x: 250, y: 250))
   try ApplicationZoomTarget.post(event, permit: permit) { _ in self.calls.append(permit.context!) }
  }
 }
 private final class Fixture {
  struct World {
   let mac: Attachment, pad: Attachment
   let control: (FakeStream, FakeStream), video: (FakeStream, FakeStream)
   var input: InputContext { InputContext(mac) }
  }
  let queue = DispatchQueue(label: "test.transport.input.handoff")
  let diagnostics = Diagnostics(), sink = ZoomSink()
  let macSecurity: AttachmentSecurity, padSecurity: AttachmentSecurity
  var host: PadAttachmentHost!, active: Attachment?
  var pencil: PencilInputPipeline!, touch: TouchInputPipeline!, zoom: ZoomController!
  var now: UInt64 = 1_000_000_000, generation: UInt32 = 0
  var streams: [FakeStream] = [], pencilEvents: [CGEventType] = [], touchEvents: [CGEvent] = []
  var workers: [() -> Void] = [], completions: [() -> Void] = [], timers: [(UInt64, () -> Void)] = []
  var stages: [String] = [], errors: [String] = [], rejects: [AttachmentEnd] = []
  init() throws {
   macSecurity = AttachmentSecurity(identity: DeviceIdentity(), store: try TrustStore())
   padSecurity = AttachmentSecurity(identity: DeviceIdentity(), store: try TrustStore())
   try macSecurity.store.put(TrustedPeer(publicKey: padSecurity.identity.publicKey,
    pairKey: macSecurity.identity.pairKey(with: padSecurity.identity.publicKey), name: "iPad"))
   try padSecurity.store.put(TrustedPeer(publicKey: macSecurity.identity.publicKey,
    pairKey: padSecurity.identity.pairKey(with: macSecurity.identity.publicKey), name: "Mac"))
   host = PadAttachmentHost(local: { [unowned self] in self.identity(self.padSecurity) }, security: padSecurity,
    queue: queue, clock: { [weak self] in self?.now ?? 0 })
   host.onAttachment = { attachment in attachment.onEvent = { _ in } }
   host.onReject = { [weak self] in self?.rejects.append($0) }
   let pb = PencilInjectionBackend(diagnostics: diagnostics, postEvent: { [weak self] in self?.pencilEvents.append($0.type) })
   pb.displayBounds = CGRect(x: 0, y: 0, width: 500, height: 500)
   pencil = PencilInputPipeline(backend: pb, diagnostics: diagnostics)
   let tb = PointerInjectionBackend { [weak self] in self?.touchEvents.append($0) }; tb.displayBounds = pb.displayBounds
   touch = TouchInputPipeline(backend: tb, diagnostics: diagnostics)
   zoom = ZoomController(clock: { [weak self] in self?.now ?? 0 },
    enqueueWorker: { [weak self] in self?.workers.append($0) }, enqueueCompletion: { [weak self] in self?.completions.append($0) },
    schedule: { [weak self] delay, fire in guard let self else { return {} }; self.timers.append((self.now + delay, fire)); return {} },
    probe: { [unowned self] _ in self.sink })
   zoom.onStage = { [weak self] _, _, stage, _ in self?.stages.append(stage) }
   MacCoordinator.connectInputs(pencil: pencil, touch: touch, zoom: zoom)
  }
  deinit { queue.sync { active?.close(.appQuit); host.closeAll(.appQuit) } }
  func identity(_ security: AttachmentSecurity) -> LocalIdentity {
   LocalIdentity(appVersion: "0.3.0", deviceID: security.identity.id)
  }
  func pair() -> (FakeStream, FakeStream) {
   let pair = FakeStream.pair(label: "handoff.\(streams.count)"); streams += [pair.0, pair.1]; return pair
  }
  func settle() { for _ in 0..<32 { streams.forEach { $0.settle() }; queue.sync {} } }
  func connect(_ transport: TransportKind) throws -> World {
   generation += 1
   let mac = Attachment(role: .mac, attachmentID: UUID(), generation: generation, local: identity(macSecurity),
    security: macSecurity, transport: transport, expectedPeerID: transport == .wifi ? padSecurity.identity.id : nil,
    trustedOnly: transport == .wifi, queue: queue, clock: { [weak self] in self?.now ?? 0 })
   mac.onEvent = { [weak self, weak mac] event in
    guard let self, let mac, self.active === mac else { return }
    MacCoordinator.inputAttachmentEvent(event, input: InputContext(mac), pencil: self.pencil, touch: self.touch)
    if case .frame(.controlInput, let frame, let stamp) = event {
     do { try MacCoordinator.receiveInput(frame, stamp: stamp, now: self.now, input: InputContext(mac),
      targetRevision: 10, target: nil, pencil: self.pencil, touch: self.touch) }
     catch { self.errors.append(String(describing: error)) }
    }
   }
   // Allow the peer to observe retirement before attempting LAN: an iPad with a live USB A
   // correctly rejects an overlapping LAN candidate as busy. Discovery retry is a separate seam.
   queue.sync { active?.close(nil) }; settle()
   let control = pair(), video = pair()
   queue.sync {
    active = mac
    host.accept(control.1, transport: transport); host.accept(video.1, transport: transport)
    mac.start(control: control.0, video: video.0)
   }
   settle()
   XCTAssertTrue(mac.isReady); let pad = try XCTUnwrap(host.current)
   XCTAssertEqual(pad.transport, transport); XCTAssertEqual(pad.attachmentID, mac.attachmentID)
   let world = World(mac: mac, pad: pad, control: control, video: video)
   try send(.presentedGeometry, PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 500, videoHeight: 500).encoded(), world)
   try send(.inputSettings, InputSettings(touchEnabled: true).encoded(), world)
   return world
  }
  func send(_ type: MessageType, _ payload: Data, _ world: World) throws {
   XCTAssertTrue(queue.sync { world.pad.send(type, payload: payload, on: .controlInput) }); settle()
   XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
  }
  func pencilPayload(_ sequence: UInt64, _ phase: PencilPhase, stroke: UInt64 = 1) throws -> Data {
   try PencilBatch([PencilSample(stroke: stroke, sequence: sequence, timestamp: now, x: 0.5, y: 0.5,
    pressure: 0.5, altitude: 1, azimuth: 0, phase: phase, geometryGeneration: 1)]).encoded()
  }
  func pen(_ sequence: UInt64, _ phase: PencilPhase, _ world: World, stroke: UInt64 = 1) throws { try send(.pencil, pencilPayload(sequence, phase, stroke: stroke), world) }
  func finger(_ sequence: UInt32, _ phase: TouchPhase, _ world: World, kind: TouchKind = .pointer, delta: Float = 0, id: UInt64 = 1) throws {
   let event = TouchEvent(gestureID: (1 << 63) + id, sequence: sequence, timestamp: now, geometryGeneration: 1,
    kind: kind, phase: phase, x: 0.5, y: 0.5, dx: delta, dy: kind == .scroll ? delta : 0)
   try send(kind.message, event.encoded(), world)
  }
  /// An already-decoded callback captured before a transport change reaches the actual ingress
  /// after replacement. It must fail the full InputContext gate, even when gesture IDs restart.
  func late(_ type: MessageType, _ payload: Data, from world: World) throws {
   try queue.sync {
    try MacCoordinator.receiveInput(Frame(type: type, generation: world.input.generation, sequence: 1, timestamp: now, payload: payload),
     stamp: ReceiveStamp(localTime: now), now: now, input: world.input, targetRevision: 10, target: nil, pencil: pencil, touch: touch)
   }
  }
  func lateEnd(_ world: World) {
   queue.sync { MacCoordinator.inputAttachmentEvent(.ended(.replaced), input: world.input, pencil: pencil, touch: touch) }
  }
  func drainZoom() {
   queue.sync {
    for _ in 0..<40 {
     if !workers.isEmpty { workers.removeFirst()() }
     else if !completions.isEmpty { completions.removeFirst()() }
     else if !timers.isEmpty { let (deadline, fire) = timers.removeFirst(); now = max(now, deadline); fire() }
     else { return }
    }
    XCTFail("zoom jobs did not retire")
   }
  }
 }

 func testRepeatedWiFiUSBWiFiHandoffReleasesPencilExactlyOnceAndRejectsOldCallbacks() throws {
  let f = try Fixture(); var world = try f.connect(.wifi)
  for _ in 0..<6 {
   for transport in [TransportKind.usb, .wifi] {
    try f.pen(1, .begin, world, stroke: 2); XCTAssertTrue(f.pencil.backend.active)
    let before = f.pencilEvents.count, old = world
    world = try f.connect(transport)
    XCTAssertEqual(Array(f.pencilEvents.dropFirst(before)), [.leftMouseUp, .tabletProximity])
    XCTAssertFalse(f.pencil.backend.active); XCTAssertNil(f.pencil.ownership.active)
    try f.pen(1, .begin, world) // Gesture IDs deliberately restart on each attachment.
    let count = f.pencilEvents.count
    try f.late(.pencil, f.pencilPayload(2, .move), from: old)
    try f.late(.pencil, f.pencilPayload(2, .end), from: old)
    try f.late(.inputCancel, GestureNotice(gestureID: 1, reason: .transportLost).encoded(), from: old)
    f.lateEnd(old); f.lateEnd(old)
    XCTAssertEqual(f.pencilEvents.count, count); XCTAssertTrue(f.pencil.backend.active)
    try f.pen(2, .end, world); XCTAssertFalse(f.pencil.backend.active)
    XCTAssertEqual(Array(f.pencilEvents.suffix(2)), [.leftMouseUp, .tabletProximity])
   }
  }
  XCTAssertTrue(f.rejects.isEmpty); XCTAssertTrue(f.macSecurity.requests.isEmpty); XCTAssertTrue(f.padSecurity.requests.isEmpty)
 }

 func testUSBUnplugReleasesTouchOnceAndNewWiFiPointerCannotBeCancelledByOldIdentity() throws {
  let f = try Fixture(), wifi = try f.connect(.wifi)
  try f.finger(1, .began, wifi)
  let usb = try f.connect(.usb)
  XCTAssertEqual(f.touchEvents.map(\.type), [.leftMouseDown, .leftMouseUp])
  try f.finger(1, .began, usb); try f.finger(2, .changed, usb)
  let before = f.touchEvents.count
  usb.control.0.fail("USB unplugged"); f.settle()
  XCTAssertEqual(Array(f.touchEvents.dropFirst(before)).map(\.type), [.leftMouseUp])
  XCTAssertNil(f.touch.ownership.active); XCTAssertFalse(f.touch.backend.pressed)
  let restored = try f.connect(.wifi); try f.finger(1, .began, restored)
  let count = f.touchEvents.count
  let oldTouch = TouchEvent(gestureID: (1 << 63) + 1, sequence: 3, timestamp: f.now,
   geometryGeneration: 1, kind: .pointer, phase: .ended, x: 0.9, y: 0.9)
  try f.late(.pointer, oldTouch.encoded(), from: usb)
  try f.late(.inputCancel, GestureNotice(gestureID: (1 << 63) + 1, reason: .transportLost).encoded(), from: usb)
  try f.late(.inputSettings, InputSettings(touchEnabled: false).encoded(), from: usb)
  try f.late(.presentedGeometry, PresentedGeometry(generation: 2, ready: false, orientation: 4, videoWidth: 500, videoHeight: 500).encoded(), from: usb)
  f.lateEnd(wifi); f.lateEnd(usb)
  XCTAssertEqual(f.touchEvents.count, count); XCTAssertTrue(f.touch.backend.pressed)
  try f.finger(2, .changed, restored); try f.finger(3, .ended, restored)
  XCTAssertEqual(Array(f.touchEvents.suffix(3)).map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
  XCTAssertFalse(f.touch.backend.pressed)
 }

 func testOrdinaryScrollSurvivesTransportChangesWithSafeTerminalAndNoCommand() throws {
  let f = try Fixture(); var world = try f.connect(.wifi)
  for transport in [TransportKind.usb, .wifi, .usb, .wifi] {
   try f.finger(1, .began, world, kind: .scroll, id: 2); try f.finger(2, .changed, world, kind: .scroll, delta: 0.02, id: 2)
   let before = f.touchEvents.count; world = try f.connect(transport)
   XCTAssertEqual(f.touchEvents.count, before + 1)
   XCTAssertEqual(f.touchEvents.last?.getIntegerValueField(.scrollWheelEventScrollPhase), 8)
   try f.finger(1, .began, world, kind: .scroll); try f.finger(2, .changed, world, kind: .scroll, delta: -0.02)
   try f.finger(3, .ended, world, kind: .scroll)
   XCTAssertEqual(f.touchEvents.last?.getIntegerValueField(.scrollWheelEventScrollPhase), 4)
  }
  XCTAssertTrue(f.touchEvents.allSatisfy { $0.type == .scrollWheel && $0.flags == [] })
  XCTAssertTrue(f.sink.calls.isEmpty); XCTAssertTrue(f.workers.isEmpty)
 }

 func testHandoffRetiresOldZoomWorkerAndCompletionThenNewAttachmentZoomWorks() throws {
  for probeAlreadyFinished in [false, true] {
   let f = try Fixture(), wifi = try f.connect(.wifi)
   try f.finger(1, .began, wifi, kind: .magnify)
   try f.finger(2, .changed, wifi, kind: .magnify, delta: 0.15)
   try f.finger(3, .ended, wifi, kind: .magnify)
   XCTAssertEqual(f.workers.count, 1)
   if probeAlreadyFinished { f.queue.sync { f.workers.removeFirst()() }; XCTAssertEqual(f.completions.count, 1) }
   let usb = try f.connect(.usb); f.drainZoom()
   XCTAssertTrue(f.sink.calls.isEmpty, "an old attachment must not post its ended zoom tail")
   try f.finger(1, .began, usb, kind: .magnify)
   try f.finger(2, .changed, usb, kind: .magnify, delta: 0.15)
   try f.finger(3, .ended, usb, kind: .magnify); f.drainZoom()
   XCTAssertEqual(f.sink.calls.count, 1); XCTAssertEqual(f.sink.calls.first?.input, usb.input)
   XCTAssertEqual(f.stages.filter { $0 == "postInvoked" }.count, 1)
   XCTAssertTrue(f.workers.isEmpty && f.completions.isEmpty && f.timers.isEmpty)
  }
 }

 func testBOnlyRebuildPreservesPressedPencilAndSameControlIdentityOnBothTransports() throws {
  for transport in [TransportKind.wifi, .usb] {
   let f = try Fixture(), world = try f.connect(transport)
   try f.pen(1, .begin, world); let count = f.pencilEvents.count
   world.video.0.fail("B-only failure"); f.settle(); f.queue.sync { world.mac.tick() }; f.settle()
   XCTAssertNil(world.mac.ended); XCTAssertNil(world.pad.ended)
   XCTAssertTrue(f.touch.inputMatches(world.input)); XCTAssertTrue(f.pencil.backend.active)
   XCTAssertEqual(f.pencilEvents.count, count)
   try f.pen(2, .move, world) // A carries input while B is absent.
   let replacement = f.pair()
   f.queue.sync { f.host.accept(replacement.1, transport: transport); world.mac.replaceVideo(replacement.0) }; f.settle()
   XCTAssertTrue(world.mac.isReady); XCTAssertTrue(f.host.current === world.pad)
   XCTAssertTrue(f.pencil.backend.active); XCTAssertTrue(f.touch.inputMatches(world.input))
   try f.pen(3, .end, world)
   XCTAssertEqual(f.pencilEvents.filter { $0 == .leftMouseUp }.count, 1)
   XCTAssertFalse(f.pencil.backend.active)
  }
 }
 func testDecodeRecoveryRebuildPreservesPressedPencilAndAuthentication() throws {
  for transport in [TransportKind.wifi, .usb] {
   let f = try Fixture(), world = try f.connect(transport)
   try f.pen(1, .begin, world); let count = f.pencilEvents.count
   f.queue.sync {
    XCTAssertTrue(world.pad.restartVideoAfterDecodeFailure())
    XCTAssertFalse(world.pad.restartVideoAfterDecodeFailure(), "one request per retired video link")
   }; f.settle(); f.queue.sync { world.mac.tick() }; f.settle()
   XCTAssertNil(world.mac.ended); XCTAssertNil(world.pad.ended)
   XCTAssertTrue(f.touch.inputMatches(world.input)); XCTAssertTrue(f.pencil.backend.active)
   XCTAssertEqual(f.pencilEvents.count, count)
   try f.pen(2, .move, world) // A carries input while B is absent.
   let replacement = f.pair()
   f.queue.sync { f.host.accept(replacement.1, transport: transport); world.mac.replaceVideo(replacement.0) }; f.settle()
   XCTAssertTrue(world.mac.isReady); XCTAssertTrue(f.host.current === world.pad)
   XCTAssertTrue(f.pencil.backend.active); XCTAssertTrue(f.touch.inputMatches(world.input))
   try f.pen(3, .end, world)
   XCTAssertEqual(f.pencilEvents.filter { $0 == .leftMouseUp }.count, 1)
   XCTAssertFalse(f.pencil.backend.active)
  }
 }
}
