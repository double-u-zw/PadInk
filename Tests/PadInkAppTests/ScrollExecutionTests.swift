import XCTest
import AppKit
import PadInkCore
@testable import PadInkMacKit

/// Synthetic finger samples exercise the production FSM and geometry helpers; UIKit capture
/// and the live transport are not simulated. From serialized ingress onward this uses the
/// real Coordinator/ownership/backend/controller wiring, replacing only external effects.
final class ScrollExecutionTests: XCTestCase {
 private final class ZoomSink: ApplicationZoomContext {
  let family = ApplicationFamily.goodnotes
  var capabilities = ApplicationCapabilities(), commands: [ZoomCommand] = []
  func execute(_ command: ZoomCommand, permit: ZoomPermit) throws {
   try permit.invoke { commands.append(command) }
  }
 }
 private final class Fixture {
  let input = InputContext(attachmentID: UUID(), generation: 7)
  let diagnostics = Diagnostics(), sink = ZoomSink()
  let bounds = CGRect(x: -100, y: 0, width: 1920, height: 1080)
  var now: UInt64 = 1_000_000_000, frameSequence: UInt64 = 0
  var decoder = FrameDecoder(connection: .controlInput)
  var events: [CGEvent] = [], pencilEvents: [CGEventType] = [], rejects: [GestureNotice] = []
  var workers: [() -> Void] = [], completions: [() -> Void] = [], timers: [(UInt64, () -> Void)] = []
  var probes = 0
  var zoom: ZoomController!, touch: TouchInputPipeline!, pencil: PencilInputPipeline!
  let target: ZoomTargetSnapshot
  init(_ family: ApplicationFamily = .goodnotes) throws {
   // CF identities only: no AX query, activation, action or real application access.
   target = ZoomTargetSnapshot(revision: 10, pid: ProcessInfo.processInfo.processIdentifier, family: family,
    app: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier), window: AXUIElementCreateSystemWide())
   zoom = ZoomController(clock: { self.now }, enqueueWorker: { self.workers.append($0) }, enqueueCompletion: { self.completions.append($0) },
    schedule: { delay, fire in self.timers.append((self.now + delay, fire)); return {} },
    probe: { _ in self.probes += 1; return self.sink })
   let backend = PointerInjectionBackend { self.events.append($0) }; backend.displayBounds = bounds
   touch = TouchInputPipeline(backend: backend, diagnostics: diagnostics)
   let pencilBackend = PencilInjectionBackend(diagnostics: diagnostics, postEvent: { self.pencilEvents.append($0.type) })
   pencilBackend.displayBounds = bounds; pencil = PencilInputPipeline(backend: pencilBackend, diagnostics: diagnostics)
   MacCoordinator.connectInputs(pencil: pencil, touch: touch, zoom: zoom)
   touch.sendReject = { self.rejects.append($0) }
   touch.attach(context: input); pencil.attach(generation: UInt64(input.generation))
   try frame(.presentedGeometry, PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 1920, videoHeight: 1080).encoded())
   try frame(.inputSettings, InputSettings(touchEnabled: true).encoded())
  }
  func frame(_ type: MessageType, _ payload: Data) throws {
   frameSequence += 1
   let wire = try Frame(type: type, generation: input.generation, sequence: frameSequence, timestamp: now, payload: payload).encoded()
   let items = try decoder.feed(wire); XCTAssertEqual(items.count, 1)
   for item in items {
    guard case .frame(let decoded) = item else { XCTFail("known input was ignored"); continue }
    try MacCoordinator.receiveInput(decoded, stamp: ReceiveStamp(localTime: now), now: now, input: input,
     targetRevision: target.revision, target: target, pencil: pencil, touch: touch)
   }
  }
  func send(_ event: TouchEvent) throws {
   now = max(now, event.timestamp); try frame(event.kind.message, event.encoded())
  }
  func acceptedSequences(_ kind: TouchKind = .scroll) -> [UInt64] {
   diagnostics.snapshot { $0.stage == "touch.inject" && $0.state?.hasPrefix(String(describing: kind) + ":") == true }.map(\.sequence)
  }
  func drain() {
   for _ in 0..<30 {
    if !workers.isEmpty { workers.removeFirst()() }
    else if !completions.isEmpty { completions.removeFirst()() }
    else if !timers.isEmpty { let (deadline, fire) = timers.removeFirst(); now = max(now, deadline); fire() }
    else { return }
   }
   XCTFail("unbounded zoom scheduler")
  }
 }
 private func event(_ sequence: UInt32, _ phase: TouchPhase, dx: Float = 0, dy: Float = 0, kind: TouchKind = .scroll, id: UInt64 = 1) -> TouchEvent {
  TouchEvent(gestureID: (1 << 63) + id, sequence: sequence, timestamp: 1_000_000_000 + UInt64(sequence) * 16_000_000,
   geometryGeneration: 1, kind: kind, phase: phase, x: 0.5, y: 0.5, dx: dx, dy: dy)
 }
 private func scroll(_ f: Fixture, dx: Float = 0, dy: Float = 0.01) throws {
  try f.send(event(1, .began)); try f.send(event(2, .changed, dx: dx, dy: dy))
  try f.send(event(3, .changed, dx: dx, dy: dy)); try f.send(event(4, .ended))
 }
 private func assertScrollOnly(_ f: Fixture, sequences: [UInt64], file: StaticString = #filePath, line: UInt = #line) {
  XCTAssertEqual(f.acceptedSequences(), sequences, file: file, line: line)
  XCTAssertEqual(f.events.map(\.type), Array(repeating: .scrollWheel, count: sequences.count), file: file, line: line)
  for event in f.events { XCTAssertEqual(event.flags, [], "ordinary ingress scroll must have no modifiers", file: file, line: line) }
  XCTAssertTrue(f.rejects.isEmpty, file: file, line: line); XCTAssertNil(f.touch.ownership.active, file: file, line: line)
  XCTAssertFalse(f.touch.backend.pressed, file: file, line: line); XCTAssertTrue(f.pencilEvents.isEmpty, file: file, line: line)
  XCTAssertTrue(f.sink.commands.isEmpty, file: file, line: line); XCTAssertEqual(f.probes, 0, file: file, line: line)
  XCTAssertTrue(f.workers.isEmpty && f.completions.isEmpty && f.timers.isEmpty, file: file, line: line)
 }
 func testAcceptedScrollLifecycleHasNonzeroChangesTerminalAndNoZoomOrPointer() throws {
  let f = try Fixture(); try scroll(f); f.drain(); assertScrollOnly(f, sequences: [1, 2, 3, 4])
  XCTAssertEqual(f.events.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [1, 2, 2, 4])
  for e in f.events[1...2] { XCTAssertLessThan(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0) }
  // Normal ended flushes subpixel remainder; its delta need not be zero.
  XCTAssertEqual(f.events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }.reduce(0, +),
   Int64((-2 * Double(Float(0.01)) * f.bounds.height).rounded()))
  let count = f.events.count; f.touch.cancel(.targetChanged); XCTAssertEqual(f.events.count, count, "ended scroll must not get another terminal")
 }
 func testContinuousSubpixelChangesPreserveMotionAndSequenceThroughRealIngress() throws {
  let f = try Fixture(); try f.send(event(1, .began))
  for sequence in 2...101 { try f.send(event(UInt32(sequence), .changed, dy: Float(0.3 / 1080))) }
  try f.send(event(102, .ended)); f.drain()
  assertScrollOnly(f, sequences: (1...102).map { UInt64($0) })
  let points = f.events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }
  XCTAssertTrue(points.dropFirst().dropLast().contains { $0 < 0 }); XCTAssertTrue(points.allSatisfy { $0 <= 0 })
  XCTAssertEqual(points.reduce(0, +), -30)
  XCTAssertEqual(f.events.compactMap { NSEvent(cgEvent: $0)?.scrollingDeltaY }.reduce(0, +), -30, accuracy: 1)
 }
 func testBothVerticalAndHorizontalDirectionsKeepSignAndAxes() throws {
  for horizontal in [false, true] { for direction in [Float(-1), Float(1)] {
   let f = try Fixture(); try scroll(f, dx: horizontal ? direction * 0.01 : 0, dy: horizontal ? 0 : direction * 0.01)
   f.drain(); assertScrollOnly(f, sequences: [1, 2, 3, 4])
   for e in f.events[1...2] {
    let moved = e.getIntegerValueField(horizontal ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventPointDeltaAxis1)
    XCTAssertLessThan(Double(moved) * Double(direction), 0)
    XCTAssertEqual(e.getIntegerValueField(horizontal ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2), 0)
   }
  } }
 }
 func testSyntheticTwoFingerTranslationClassifiesScrollAndReachesSerializedIngress() throws {
  for direction in [-1.0, 1.0] {
   let f = try Fixture(); var classifier = GestureFSM(); classifier.touchEnabled = true
   let geometry = VideoGeometry(source: CGSize(width: 1920, height: 1080), bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000))
   func pair(_ offset: Double) -> [FingerPoint] { [FingerPoint(1, CGPoint(x: 400, y: 500 + offset)), FingerPoint(2, CGPoint(x: 600, y: 500 + offset))] }
   XCTAssertTrue(classifier.update(pair(0), now: 1_000_000_000).isEmpty)
   var actions = classifier.update(pair(direction * 20), now: 1_100_000_000)
   actions += classifier.update(pair(direction * 40), now: 1_116_000_000)
   actions += classifier.update([pair(direction * 40)[1]], now: 1_132_000_000)
   XCTAssertEqual(actions.map(\.kind), [.scroll, .scroll, .scroll, .scroll])
   XCTAssertEqual(actions.map(\.phase), [.began, .changed, .changed, .ended]); XCTAssertEqual(actions.map(\.sequence), [1, 2, 3, 4])
   XCTAssertEqual(Set(actions.map(\.id)).count, 1)
   // Uses the production geometry helpers; this is not execution of UIKit TouchCapture.emit.
   for a in actions {
    let p = try XCTUnwrap(geometry.normalized(a.point, clamp: a.phase != .began)), d = geometry.normalizedDelta(a.delta)
    try f.send(TouchEvent(gestureID: a.id, sequence: a.sequence, timestamp: a.timestamp, geometryGeneration: 1,
     kind: a.kind, phase: a.phase, clickCount: a.clicks, x: Float(p.x), y: Float(p.y), dx: Float(d.x), dy: Float(d.y)))
   }
   f.drain(); assertScrollOnly(f, sequences: [1, 2, 3, 4])
   XCTAssertEqual(f.events.compactMap { NSEvent(cgEvent: $0)?.phase }, [.began, .changed, .changed, .ended])
   XCTAssertEqual(f.events.map(\.location), Array(repeating: CGPoint(x: 860, y: 540), count: 4))
   XCTAssertTrue(f.events[1...2].allSatisfy { Double($0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) * direction < 0 })
  }
 }
 private func fields(_ e: CGEvent) -> [String: Int64] {
  let fields: [(String, CGEventField)] = [
   ("integerY", .scrollWheelEventDeltaAxis1), ("integerX", .scrollWheelEventDeltaAxis2),
   ("fixedYRaw", .scrollWheelEventFixedPtDeltaAxis1), ("fixedXRaw", .scrollWheelEventFixedPtDeltaAxis2),
   ("pointY", .scrollWheelEventPointDeltaAxis1), ("pointX", .scrollWheelEventPointDeltaAxis2),
   ("continuous", .scrollWheelEventIsContinuous), ("phase", .scrollWheelEventScrollPhase),
   ("momentum", .scrollWheelEventMomentumPhase), ("scrollCount", .scrollWheelEventScrollCount),
   ("sourceState", .eventSourceStateID), ("sourcePID", .eventSourceUnixProcessID)]
  return Dictionary(uniqueKeysWithValues: fields.map { ($0.0, e.getIntegerValueField($0.1)) })
 }
 func testGoodnotesPreviewSafariChromeUseIdenticalScrollConstructionAndRecordFields() throws {
  var baseline: [[String: Int64]]?, locations: [CGPoint]?, report: [[String: Any]] = []
  for family in [ApplicationFamily.goodnotes, .preview, .safari, .chrome] {
   let f = try Fixture(family); try scroll(f, dx: 0.01, dy: 0.01); f.drain(); assertScrollOnly(f, sequences: [1, 2, 3, 4])
   let actual = f.events.map(fields)
   if let baseline { XCTAssertEqual(actual, baseline); XCTAssertEqual(f.events.map(\.location), locations!) }
   else { baseline = actual; locations = f.events.map(\.location) }
   for e in f.events {
    XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
    XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventMomentumPhase), 0)
    XCTAssertEqual(e.getIntegerValueField(.eventSourceStateID), Int64(CGEventSourceStateID.hidSystemState.rawValue))
    // Observe constructor timestamp before posting; no assumption about WindowServer stamping.
    let n = try XCTUnwrap(NSEvent(cgEvent: e)); XCTAssertTrue(n.hasPreciseScrollingDeltas); XCTAssertEqual(n.momentumPhase, [])
    var row: [String: Any] = fields(e).mapValues { $0 as Any }
    row["targetFamily"] = family.rawValue; row["timestamp"] = e.timestamp; row["flags"] = e.flags.rawValue
    row["location"] = [e.location.x, e.location.y]; row["fixedY"] = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    row["fixedX"] = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
    row["appKitDelta"] = [n.deltaX, n.deltaY]; row["appKitScrollingDelta"] = [n.scrollingDeltaX, n.scrollingDeltaY]
    report.append(row)
   }
  }
  // Optional bounded artifact from this test sink, without changing product diagnostics.
  if let path = ProcessInfo.processInfo.environment["PADINK_SCROLL_EVENT_REPORT"] {
   try JSONSerialization.data(withJSONObject: ["constructorUnits": "pixel", "constructorWheelCount": 2, "events": report], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
  }
 }
 func testAcceptedScrollCannotRunAnOldZoomTailAndStillDeliversEveryPhase() throws {
  let f = try Fixture()
  try f.send(event(1, .began, kind: .magnify, id: 2)); try f.send(event(2, .changed, dx: 0.15, kind: .magnify, id: 2))
  try f.send(event(3, .ended, kind: .magnify, id: 2)); XCTAssertEqual(f.workers.count, 1)
  try scroll(f); f.drain(); assertScrollOnly(f, sequences: [1, 2, 3, 4])
  XCTAssertEqual(f.events.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [1, 2, 2, 4])
 }
 /// Seed inherited modifiers immediately before the production final post boundary.
 /// Events come from the real serialized ingress/backend builder; no alternate scroll builder
 /// or global keyboard events are used to manufacture HID state.
 private func assertOrdinaryScrollFinalPost(_ originals: [CGEvent], inheritedFlags: CGEventFlags = .maskCommand,
  file: StaticString = #filePath, line: UInt = #line) throws {
  var posted: [CGEvent] = []
  let backend = PointerInjectionBackend { posted.append($0) }
  for original in originals {
   let polluted = try XCTUnwrap(original.copy(), file: file, line: line)
   polluted.flags = inheritedFlags
   XCTAssertTrue(polluted.flags.contains(.maskCommand), "negative-control fixture must contain Command", file: file, line: line)
   backend.postOrdinaryScroll(polluted)
   let actual = try XCTUnwrap(posted.last, file: file, line: line)
   XCTAssertFalse(actual.flags.contains(.maskCommand), "ordinary scroll contains Command", file: file, line: line)
   XCTAssertEqual(actual.flags, [], "ordinary scroll must have no modifiers", file: file, line: line)
   XCTAssertEqual(actual.type, original.type, file: file, line: line)
   XCTAssertEqual(fields(actual), fields(original), "delta/phase/continuous/momentum/source fields changed", file: file, line: line)
   for field in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
    XCTAssertEqual(actual.getDoubleValueField(field), original.getDoubleValueField(field), file: file, line: line)
   }
   XCTAssertEqual(actual.timestamp, original.timestamp, file: file, line: line)
   XCTAssertEqual(actual.location, original.location, file: file, line: line)
   let before = try XCTUnwrap(NSEvent(cgEvent: original)), after = try XCTUnwrap(NSEvent(cgEvent: actual))
   XCTAssertEqual(after.hasPreciseScrollingDeltas, before.hasPreciseScrollingDeltas, "pixel units changed", file: file, line: line)
   XCTAssertEqual(after.scrollingDeltaX, before.scrollingDeltaX, file: file, line: line)
   XCTAssertEqual(after.scrollingDeltaY, before.scrollingDeltaY, file: file, line: line)
  }
  XCTAssertEqual(posted.count, originals.count, file: file, line: line)
 }
 func testOrdinaryScrollFinalPostRemovesCommandFromBeganChangedAndEnded() throws {
  for direction in [Float(-1), Float(1)] {
   let f = try Fixture(); try scroll(f, dx: direction * 0.01, dy: direction * 0.01)
   assertScrollOnly(f, sequences: [1, 2, 3, 4])
   XCTAssertEqual(f.events.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [1, 2, 2, 4])
   try assertOrdinaryScrollFinalPost(f.events)
  }
 }
 func testOrdinaryScrollFinalPostRemovesCommandFromCancelledTerminal() throws {
  let f = try Fixture(); try f.send(event(1, .began)); try f.send(event(2, .changed, dy: 0.01)); try f.send(event(3, .cancelled))
  assertScrollOnly(f, sequences: [1, 2, 3])
  XCTAssertEqual(f.events.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [1, 2, 8])
  XCTAssertEqual(f.events.last?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
  try assertOrdinaryScrollFinalPost(f.events)
 }
 func testOrdinaryScrollFinalPostClearsModifiersAndPreservesSubpixelResidual() throws {
  let f = try Fixture(); try f.send(event(1, .began))
  for sequence in 2...11 { try f.send(event(UInt32(sequence), .changed, dy: Float(0.3 / 1080))) }
  try f.send(event(12, .ended)); assertScrollOnly(f, sequences: (1...12).map { UInt64($0) })
  XCTAssertEqual(f.events.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }.reduce(0, +), -3)
  try assertOrdinaryScrollFinalPost(f.events, inheritedFlags: [.maskCommand, .maskShift, .maskAlternate, .maskControl])
 }
 func testGoodnotesZoomKeepsExplicitCommandAfterOrdinaryScrollFinalPost() throws {
  let point = CGPoint(x: 640, y: 480)
  let zoomIn = try GoodnotesPublicZoom.event(.zoomIn, at: point), zoomOut = try GoodnotesPublicZoom.event(.zoomOut, at: point)
  let f = try Fixture(); try scroll(f); try assertOrdinaryScrollFinalPost(f.events)
  for e in [zoomIn, zoomOut] {
   XCTAssertEqual(e.flags, .maskCommand)
   XCTAssertEqual(e.location, point)
   XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
   XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventIsContinuous), 0)
   XCTAssertFalse(try XCTUnwrap(NSEvent(cgEvent: e)).hasPreciseScrollingDeltas)
  }
  XCTAssertEqual(zoomIn.getIntegerValueField(.scrollWheelEventDeltaAxis1), -1)
  XCTAssertEqual(zoomOut.getIntegerValueField(.scrollWheelEventDeltaAxis1), 1)
 }
 func testZoomObservationPositiveControlReallySeesACommand() throws {
  let f = try Fixture(); try f.send(event(1, .began, kind: .magnify))
  try f.send(event(2, .changed, dx: 0.15, kind: .magnify)); try f.send(event(3, .ended, kind: .magnify)); f.drain()
  XCTAssertEqual(f.probes, 1); XCTAssertEqual(f.sink.commands, [.zoomIn]); XCTAssertTrue(f.events.isEmpty)
 }
}
