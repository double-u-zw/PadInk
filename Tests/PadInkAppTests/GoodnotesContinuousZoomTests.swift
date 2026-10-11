import XCTest
import AppKit
import PadInkCore
@testable import PadInkMacKit

/// The real Coordinator, ownership, backend and controller feed the real pixel event builder
/// and final execution claim. Virtual executors replace OS effects only; no AX queries or posts.
final class GoodnotesContinuousZoomTests: XCTestCase {
 private let frameInterval: UInt64 = 16_666_667
 private final class Sink: ApplicationZoomContext {
  let family = ApplicationFamily.goodnotes
  var supportsContinuousZoom = true, capabilities = ApplicationCapabilities()
  struct Post { let event: CGEvent, context: ZoomActionContext, job: UUID, time: UInt64 }
  var posts: [Post] = [], commands: [ZoomCommand] = [], commandTimes: [UInt64] = [], clock: () -> UInt64 = { 0 }
  var beforeClaim: (ZoomPermit) -> Void = { _ in }, duringCall: (ZoomPermit) -> Void = { _ in }
  var attemptSecondPost = false
  func execute(_ command: ZoomCommand, permit: ZoomPermit) throws {
   let event = try GoodnotesPublicZoom.event(command, at: CGPoint(x: 100, y: 100))
   try ApplicationZoomTarget.post(event, permit: permit) { _ in commands.append(command); commandTimes.append(clock()) }
  }
  func executePixelZoom(_ delta: Int32, permit: ZoomPermit) throws {
   let event = try GoodnotesPublicZoom.pixelEvent(delta, at: CGPoint(x: 100, y: 100))
   beforeClaim(permit)
   try ApplicationZoomTarget.post(event, permit: permit) { event in
    posts.append(Post(event: event, context: permit.context!, job: permit.jobID!, time: clock()))
    duringCall(permit)
   }
   if attemptSecondPost {
    XCTAssertThrowsError(try ApplicationZoomTarget.post(event, permit: permit) { _ in
     XCTFail("cancelled permit granted a second pixel post")
    })
   }
  }
 }
 private final class Fixture {
  final class Timer { let deadline: UInt64, fire: () -> Void; var cancelled = false
   init(_ deadline: UInt64, _ fire: @escaping () -> Void) { self.deadline = deadline; self.fire = fire }
  }
  var now: UInt64 = 1_000_000_000, workers: [() -> Void] = [], completions: [() -> Void] = [], timers: [Timer] = []
  var input = InputContext(attachmentID: UUID(), generation: 7), revision: UInt64 = 10
  let diagnostics = Diagnostics(), sink = Sink()
  var events: [CGEvent] = [], pencilEvents: [CGEventType] = [], rejects: [GestureNotice] = []
  var stages: [(UUID, UUID?, String)] = [], probes: [ZoomActionContext] = [], failures: [String] = []
  var maximumWorkers = 0, maximumCompletions = 0
  var zoom: ZoomController!, touch: TouchInputPipeline!, pencil: PencilInputPipeline!
  init(continuous: Bool = true) {
   sink.supportsContinuousZoom = continuous; sink.clock = { self.now }
   zoom = ZoomController(clock: { self.now }, enqueueWorker: {
    self.workers.append($0); self.maximumWorkers = max(self.maximumWorkers, self.workers.count)
   }, enqueueCompletion: {
    self.completions.append($0); self.maximumCompletions = max(self.maximumCompletions, self.completions.count)
   }, schedule: { delay, fire in
    let timer = Timer(self.now + delay, fire); self.timers.append(timer); return { timer.cancelled = true }
   }, probe: { permit in self.probes.append(permit.context!); return self.sink })
   zoom.onStage = { c, job, stage, _ in self.stages.append((c.actionID, job, stage)) }
   zoom.onFailure = { self.failures.append($0) }
   let backend = PointerInjectionBackend { self.events.append($0) }
   backend.displayBounds = CGRect(x: 0, y: 0, width: 500, height: 500)
   touch = TouchInputPipeline(backend: backend, diagnostics: diagnostics)
   let pencilBackend = PencilInjectionBackend(diagnostics: diagnostics, postEvent: { self.pencilEvents.append($0.type) })
   pencilBackend.displayBounds = backend.displayBounds
   pencil = PencilInputPipeline(backend: pencilBackend, diagnostics: diagnostics)
   MacCoordinator.connectInputs(pencil: pencil, touch: touch, zoom: zoom)
   touch.sendReject = { self.rejects.append($0) }
   attach(input)
  }
  func frame(_ type: MessageType, _ payload: Data, input supplied: InputContext? = nil) {
   let c = supplied ?? input
   let frame = Frame(type: type, generation: c.generation, sequence: 1, timestamp: now, payload: payload)
   do { try MacCoordinator.receiveInput(frame, stamp: ReceiveStamp(localTime: now), now: now, input: c,
    targetRevision: revision, target: nil, pencil: pencil, touch: touch) }
   catch { XCTFail("real ingress rejected fixture: \(error)") }
  }
  func send(_ sequence: UInt32, _ phase: TouchPhase, delta: Float = 0, id: UInt64 = 1, kind: TouchKind = .magnify, dy: Float = 0, input: InputContext? = nil) {
   let event = TouchEvent(gestureID: (1 << 63) + id, sequence: sequence, timestamp: now,
    geometryGeneration: 1, kind: kind, phase: phase, x: 0.5, y: 0.5, dx: delta, dy: dy)
   frame(kind.message, try! event.encoded(), input: input)
  }
  func geometry(_ generation: UInt32, ready: Bool = true, input: InputContext? = nil) {
   frame(.presentedGeometry, PresentedGeometry(generation: generation, ready: ready, orientation: 4,
    videoWidth: 500, videoHeight: 500).encoded(), input: input)
  }
  func attach(_ next: InputContext) {
   input = next; touch.attach(context: next); pencil.attach(generation: UInt64(next.generation))
   geometry(1); frame(.inputSettings, InputSettings(touchEnabled: true).encoded())
  }
  func cancel(_ id: UInt64 = 1, input: InputContext? = nil) {
   frame(.inputCancel, GestureNotice(gestureID: (1 << 63) + id, reason: .appBackground).encoded(), input: input)
  }
  func target(_ revision: UInt64) { self.revision = revision; MacCoordinator.targetChanged(to: revision, input: input, touch: touch) }
  func pencilBegin() {
   let sample = PencilSample(stroke: 1, sequence: 1, timestamp: now, x: 0.5, y: 0.5,
    pressure: 0.5, altitude: 1, azimuth: 0, phase: .begin, geometryGeneration: 1)
   frame(.pencil, try! PencilBatch([sample]).encoded())
  }
  func worker() { XCTAssertEqual(workers.count, 1, "one occupied physical job"); guard !workers.isEmpty else { return }; workers.removeFirst()() }
  @discardableResult func complete() -> (() -> Void)? {
   XCTAssertEqual(completions.count, 1); guard !completions.isEmpty else { return nil }
   let callback = completions.removeFirst(); callback(); return callback
  }
  func probe() { worker(); complete() }
  func begin(_ id: UInt64 = 1) { send(1, .began, id: id); probe() }
  func immediate() {
   for _ in 0..<100 {
    if !workers.isEmpty { worker() }
    else if !completions.isEmpty { complete() }
    else { return }
   }
   XCTFail("unbounded immediate executor")
  }
  func advance(_ duration: UInt64) { advanceTo(now + duration) }
  /// Fire timers at their own deadlines before the next recorded input; time never moves back.
  func advanceTo(_ target: UInt64) {
   let destination = max(now, target)
   for _ in 0..<100 {
    timers.removeAll { $0.cancelled }
    if let index = timers.indices.filter({ timers[$0].deadline <= destination }).min(by: { timers[$0].deadline < timers[$1].deadline }) {
     let timer = timers.remove(at: index); now = max(now, timer.deadline); timer.fire(); immediate()
    } else { now = max(now, destination); return }
   }
   XCTFail("unbounded due timer executor")
  }
  func drain() {
   for _ in 0..<100 {
    immediate(); timers.removeAll { $0.cancelled }
    guard let index = timers.indices.min(by: { timers[$0].deadline < timers[$1].deadline }) else { return }
    let timer = timers.remove(at: index); now = max(now, timer.deadline); timer.fire()
   }
   XCTFail("unbounded continuous scheduler")
  }
  var deltas: [Int64] { sink.posts.map { $0.event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) } }
  func assertIdle(file: StaticString = #filePath, line: UInt = #line) {
   XCTAssertTrue(workers.isEmpty && completions.isEmpty && timers.allSatisfy(\.cancelled), file: file, line: line)
   XCTAssertLessThanOrEqual(maximumWorkers, 1, file: file, line: line)
   XCTAssertLessThanOrEqual(maximumCompletions, 1, file: file, line: line)
  }
 }
 private func metrics(_ fixture: Fixture, continuous: Bool) -> [String: Any] {
  let times = continuous ? fixture.sink.posts.map(\.time) : fixture.sink.commandTimes
  let cadence = zip(times.dropFirst(), times).map { $0 - $1 }
  let sortedCadence = cadence.sorted(), deltas = fixture.deltas
  let median: Double? = sortedCadence.isEmpty ? nil : sortedCadence.count % 2 == 1
   ? Double(sortedCadence[sortedCadence.count / 2])
   : (Double(sortedCadence[sortedCadence.count / 2 - 1]) + Double(sortedCadence[sortedCadence.count / 2])) / 2
  return ["mode": continuous ? "continuous" : "stepped", "postCount": times.count,
   "postTimesNs": times, "cadenceNs": cadence, "medianCadenceNs": median.map { $0 as Any } ?? NSNull(),
   "pixelDeltas": deltas, "commands": fixture.sink.commands.map(\.rawValue),
   "workerQueueMax": fixture.maximumWorkers, "completionQueueMax": fixture.maximumCompletions,
   "probeCount": fixture.probes.count, "maximumAbsolutePixelDelta": deltas.map { abs($0) }.max() ?? 0]
 }
 private func writeComparison(_ key: String, value: Any) throws {
  guard let path = ProcessInfo.processInfo.environment["PADINK_ZOOM_COMPARISON_REPORT"] else { return }
  let url = URL(fileURLWithPath: path)
  var report: [String: Any] = [:]
  if let data = try? Data(contentsOf: url), let prior = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { report = prior }
  report["virtualExecutorsOnly"] = true
  report["interpretation"] = "Captured log input exercises product control flow; no real GoodNotes rendering or acceptance is measured."
  report[key] = value
  try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
 }
 func testContinuousPixelBuilderHasExplicitCommandAndNoMomentumOrScrollTail() throws {
  for delta: Int32 in [-32, -1, 1, 32] {
   let point = CGPoint(x: 100, y: 100), event = try GoodnotesPublicZoom.pixelEvent(delta, at: point)
   XCTAssertEqual(event.type, .scrollWheel); XCTAssertEqual(event.flags, .maskCommand); XCTAssertEqual(event.location, point)
   XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), Int64(delta))
   XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 0)
   XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
   XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
   XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), 0)
   let appKit = try XCTUnwrap(NSEvent(cgEvent: event)); XCTAssertTrue(appKit.hasPreciseScrollingDeltas)
   XCTAssertEqual(appKit.scrollingDeltaY, CGFloat(delta)); XCTAssertEqual(appKit.scrollingDeltaX, 0)
  }
 }
 func testSixtyHertzRealIngressProducesSmallContinuousDeltasInBothDirections() {
  for direction: Float in [1, -1] {
   let f = Fixture(); f.begin()
   for sequence: UInt32 in 2...61 {
    if sequence > 2 { f.advance(frameInterval) }
    f.send(sequence, .changed, delta: direction * 0.0125); f.immediate()
   }
   XCTAssertEqual(f.sink.posts.count, 60, "each 60 Hz sample can produce a continuous pixel event")
   XCTAssertEqual(f.deltas, Array(repeating: direction > 0 ? -2 : 2, count: 60))
   let cadence = zip(f.sink.posts.dropFirst(), f.sink.posts).map { $0.time - $1.time }
   XCTAssertEqual(cadence, Array(repeating: frameInterval, count: 59))
   XCTAssertEqual(f.probes.count, 1); XCTAssertTrue(f.sink.commands.isEmpty)
   XCTAssertTrue(f.events.isEmpty && f.rejects.isEmpty)
   f.send(62, .ended); f.drain(); XCTAssertEqual(f.sink.posts.count, 60); f.assertIdle()
  }
 }
 func testSameLogInputDistinguishesContinuousFromSteppedBaseline() throws {
  let continuous = Fixture(), stepped = Fixture(continuous: false)
  continuous.begin(); stepped.begin()
  for sequence: UInt32 in 2...61 {
   if sequence > 2 { continuous.advance(frameInterval); stepped.advance(frameInterval) }
   continuous.send(sequence, .changed, delta: 0.0125); stepped.send(sequence, .changed, delta: 0.0125)
   continuous.immediate(); stepped.immediate()
  }
  XCTAssertEqual(continuous.sink.posts.count, 60); XCTAssertTrue(continuous.sink.commands.isEmpty)
  XCTAssertTrue(stepped.sink.posts.isEmpty); XCTAssertGreaterThan(stepped.sink.commands.count, 0)
  XCTAssertLessThanOrEqual(stepped.sink.commands.count, 6)
  XCTAssertGreaterThan(continuous.sink.posts.count, stepped.sink.commands.count * 5)
  try writeComparison("synthetic60Hz", value: ["inputCount": 60, "inputLogDelta": 0.0125,
   "continuous": metrics(continuous, continuous: true), "stepped": metrics(stepped, continuous: false)])
 }
 func testSmallSubpixelChangesAccumulateWithoutOldDiscreteThreshold() {
  for direction: Float in [1, -1] {
   let f = Fixture(); f.begin()
   for sequence: UInt32 in 2...21 {
    if sequence > 2 { f.advance(frameInterval) }
    f.send(sequence, .changed, delta: direction * 0.002); f.immediate()
   }
   XCTAssertEqual(f.deltas.reduce(0, +), direction > 0 ? -6 : 6)
   XCTAssertTrue(f.deltas.allSatisfy { direction > 0 ? $0 < 0 : $0 > 0 })
   XCTAssertTrue(f.sink.commands.isEmpty)
   f.send(22, .ended); let count = f.sink.posts.count; f.drain(); XCTAssertEqual(f.sink.posts.count, count)
  }
 }
 func testMicroCorrectionsPreserveNetOutwardMovement() {
  let f = Fixture(); f.begin()
  var sequence: UInt32 = 2
  for _ in 0..<30 {
   f.advance(frameInterval); f.send(sequence, .changed, delta: 0.01); f.immediate(); sequence += 1
   f.advance(frameInterval); f.send(sequence, .changed, delta: -0.0001); f.immediate(); sequence += 1
  }
  XCTAssertFalse(f.deltas.isEmpty)
  XCTAssertLessThan(f.deltas.reduce(0, +), 0, "tiny corrections must not swallow sustained outward zoom")
  XCTAssertTrue(f.sink.commands.isEmpty)
  f.send(sequence, .ended); let count = f.sink.posts.count; f.drain(); XCTAssertEqual(f.sink.posts.count, count)
 }
 func testFreshnessExpiresDuringPreparationBeforeFinalClaim() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.2)
  f.sink.beforeClaim = { _ in f.now += 100_000_001 }; f.drain()
  XCTAssertTrue(f.sink.posts.isEmpty, "preparation cannot extend a batch beyond the 100ms input freshness window")
  XCTAssertTrue(f.stages.filter { $0.2 == "claimed" }.isEmpty); f.assertIdle()
 }
 func testBusyWorkerMicroCorrectionsDoNotEraseNetOutwardTravel() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.01)
  var sequence: UInt32 = 3
  for _ in 0..<30 {
   f.now += 10_000; f.send(sequence, .changed, delta: 0.01); sequence += 1
   f.now += 10_000; f.send(sequence, .changed, delta: -0.0001); sequence += 1
  }
  XCTAssertEqual(f.workers.count, 1, "busy physical slot stays bounded despite corrections")
  f.drain(); XCTAssertFalse(f.deltas.isEmpty)
  XCTAssertLessThan(f.deltas.reduce(0, +), 0, "tiny corrections during backpressure must not erase net outward pinch")
  XCTAssertTrue(f.deltas.allSatisfy { $0 < 0 }, "subpixel corrections must not manufacture inward zoom")
  XCTAssertEqual(f.probes.count, 1); XCTAssertTrue(f.failures.isEmpty)
  let count = f.sink.posts.count; f.send(sequence, .ended); f.drain(); XCTAssertEqual(f.sink.posts.count, count); f.assertIdle()
 }
 func testSustainedSubpixelReversalRevokesQueuedOldDirectionOncePixelAccumulates() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.05)
  for sequence: UInt32 in 3...6 { f.send(sequence, .changed, delta: -0.002) }
  XCTAssertEqual(f.workers.count, 1, "old physical slot remains until its cancelled job retires")
  f.drain(); XCTAssertFalse(f.deltas.isEmpty, "four subpixel reversals accumulate enough new-direction movement")
  XCTAssertTrue(f.deltas.allSatisfy { $0 > 0 }, "confirmed reversal must revoke unclaimed old-direction batch")
  XCTAssertEqual(Set(f.sink.posts.map { $0.context.actionID }).count, 1)
  XCTAssertEqual(f.probes.count, 1); XCTAssertTrue(f.sink.commands.isEmpty)
 }
 func testExpiredSubpixelReverseTravelCannotBecomeFreshPixelPost() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.0125); f.immediate()
  XCTAssertEqual(f.deltas, [-2])
  f.send(3, .changed, delta: -0.005625) // .9 pixel of opposing travel, below reversal confirmation
  f.now += 100_000_001
  f.send(4, .changed, delta: -0.000625) // fresh .1 pixel must not combine with expired .9
  f.drain()
  XCTAssertEqual(f.deltas, [-2], "expired reverse travel must be cleared before deciding to replace the action")
  f.advance(frameInterval); f.send(5, .changed, delta: -0.005625); f.immediate()
  XCTAssertEqual(f.deltas, [-2, 1], "only the two fresh corrections can confirm a new-direction pixel")
  f.send(6, .ended); f.drain(); f.assertIdle()
 }
 func testFreshnessDeadlineStartsAtInputRatherThanBatchSelection() {
  let f = Fixture(); f.send(1, .began); f.send(2, .changed, delta: 0.2)
  f.now += 90_000_000 // live input waits behind the capability probe
  f.sink.beforeClaim = { _ in f.now += 20_000_000 }
  f.probe(); f.drain()
  XCTAssertTrue(f.sink.posts.isEmpty, "110ms-old input must not gain a new 100ms lease when selected at t90ms")
  XCTAssertTrue(f.stages.filter { $0.2 == "claimed" }.isEmpty); XCTAssertTrue(f.failures.isEmpty); f.assertIdle()
 }
 func testReversalCancelsQueuedOldDirectionBeforeItsClaim() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.05)
  XCTAssertEqual(f.workers.count, 1)
  f.send(3, .changed, delta: -0.05); XCTAssertEqual(f.workers.count, 1, "old physical slot remains occupied")
  f.drain(); XCTAssertFalse(f.deltas.isEmpty); XCTAssertTrue(f.deltas.allSatisfy { $0 > 0 }, "queued old direction must not post after reversal")
  XCTAssertEqual(Set(f.sink.posts.map { $0.context.actionID }).count, 1)
  XCTAssertEqual(f.probes.count, 1, "same pinned target remains usable through reversal")
 }
 func testReversalDropsOldTimerDemandAndSubpixelResidual() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.02); f.immediate()
  XCTAssertEqual(f.deltas, [-3])
  f.send(3, .changed, delta: 0.02); f.send(4, .changed, delta: -0.02); f.drain()
  XCTAssertEqual(f.deltas.first, -3); XCTAssertTrue(f.deltas.dropFirst().allSatisfy { $0 > 0 })
  XCTAssertEqual(f.deltas.dropFirst().reduce(0, +), 3, "new direction starts without old fractional travel")
 }
 func testEndedBeforeProbeReturnDropsPendingMovement() {
  let f = Fixture(); f.send(1, .began); f.send(2, .changed, delta: 0.2); f.send(3, .ended)
  XCTAssertEqual(f.workers.count, 1); f.drain()
  XCTAssertTrue(f.sink.posts.isEmpty && f.sink.commands.isEmpty); XCTAssertNil(f.touch.ownership.active); f.assertIdle()
 }
 func testEndedBeforeQueuedExecutionClaimPostsNothing() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.2); f.send(3, .ended); f.drain()
  XCTAssertTrue(f.sink.posts.isEmpty); XCTAssertTrue(f.stages.filter { $0.2 == "claimed" }.isEmpty); f.assertIdle()
 }
 func testEndedAtFinalClaimBarrierPostsNothing() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.2)
  f.sink.beforeClaim = { _ in f.send(3, .ended) }; f.drain()
  XCTAssertTrue(f.sink.posts.isEmpty); XCTAssertTrue(f.stages.filter { $0.2 == "claimed" }.isEmpty); f.assertIdle()
 }
 func testClaimBeforeCancelAllowsOneCallAndNeverGrantsAnother() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.2)
  f.sink.duringCall = { _ in f.cancel() }; f.sink.attemptSecondPost = true; f.drain()
  XCTAssertEqual(f.sink.posts.count, 1); XCTAssertEqual(f.stages.filter { $0.2 == "claimed" }.count, 1); f.assertIdle()
 }
 func testTargetAttachmentGeometryPencilAndPeerCancelFenceQueuedPixelWork() {
  for mode in 0..<6 {
   let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.2)
   switch mode {
   case 0: f.target(11)
   case 1: MacCoordinator.inputAttachmentEvent(.ended(.closedLocally(.userDisconnect)), input: f.input, pencil: f.pencil, touch: f.touch)
   case 2: f.geometry(2)
   case 3: f.pencilBegin(); XCTAssertTrue(f.pencil.backend.active)
   case 4: f.cancel()
   default: f.send(3, .cancelled)
   }
   f.drain(); XCTAssertTrue(f.sink.posts.isEmpty, "invalidation mode \(mode)"); f.assertIdle()
  }
 }
 func testCancelledStaleTimerNeverPostsOldPixelDemand() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.05); f.immediate()
  f.send(3, .changed, delta: 0.05); let old = f.timers.last
  f.cancel(); old?.fire(); f.drain()
  XCTAssertEqual(f.sink.posts.count, 1); f.assertIdle()
 }
 func testSlowPhysicalWorkerCoalescesBurstIntoBoundedDemand() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.02)
  for sequence: UInt32 in 3...1002 { f.now += 10_000; f.send(sequence, .changed, delta: 0.02) }
  XCTAssertEqual(f.workers.count, 1); XCTAssertTrue(f.completions.isEmpty)
  f.drain(); XCTAssertLessThanOrEqual(f.sink.posts.count, 3)
  XCTAssertTrue(f.deltas.allSatisfy { abs($0) <= 64 }); XCTAssertEqual(f.maximumWorkers, 1)
  XCTAssertEqual(f.probes.count, 1); XCTAssertTrue(f.failures.isEmpty)
  let count = f.sink.posts.count; f.send(1003, .ended); f.drain(); XCTAssertEqual(f.sink.posts.count, count); f.assertIdle()
 }
 func testPixelWorkOlderThanFreshnessWindowNeverClaims() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.2); f.now += 100_000_001; f.drain()
  XCTAssertTrue(f.sink.posts.isEmpty, "100ms-old queued movement must not replay")
  XCTAssertTrue(f.stages.filter { $0.2 == "claimed" }.isEmpty); XCTAssertTrue(f.failures.isEmpty)
 }
 func testDuplicateOldCompletionCannotRetireReplacementPhysicalJob() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.05); f.worker()
  f.send(1, .began, id: 2); f.send(2, .changed, delta: -0.05, id: 2)
  guard let old = f.complete() else { return }; XCTAssertEqual(f.workers.count, 1)
  old(); XCTAssertEqual(f.workers.count, 1); f.drain()
  XCTAssertEqual(f.sink.posts.map { $0.context.gestureID }, [(1 << 63) + 1, (1 << 63) + 2])
  XCTAssertLessThanOrEqual(f.maximumWorkers, 1); XCTAssertLessThanOrEqual(f.maximumCompletions, 1)
 }
 func testOldProbeCompletionCannotApplyToNewGesture() {
  let f = Fixture(); f.send(1, .began); f.send(2, .changed, delta: 0.05); f.worker()
  f.send(1, .began, id: 2); f.send(2, .changed, delta: -0.05, id: 2)
  f.complete(); f.drain()
  XCTAssertEqual(f.probes.map(\.gestureID), [(1 << 63) + 1, (1 << 63) + 2])
  XCTAssertEqual(f.sink.posts.map { $0.context.gestureID }, [(1 << 63) + 2])
  XCTAssertTrue(f.deltas.allSatisfy { $0 > 0 })
 }
 func testOldAttachmentCallbacksCannotCancelNewSameGenerationAction() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.05); f.worker(); let old = f.input
  f.attach(InputContext(attachmentID: UUID(), generation: old.generation)); f.send(1, .began); f.send(2, .changed, delta: -0.05)
  f.cancel(input: old); f.geometry(2, input: old)
  MacCoordinator.inputAttachmentEvent(.ended(.replaced), input: old, pencil: f.pencil, touch: f.touch)
  f.complete(); f.drain()
  XCTAssertEqual(f.sink.posts.map { $0.context.input }, [old, f.input])
  guard let last = f.deltas.last else { return XCTFail("replacement action did not produce a continuous pixel post") }
  XCTAssertGreaterThan(last, 0)
 }
 /// Optional evidence replay; the normal suite needs no external diagnostic file.
 func testOptionalCapturedGoodnotesMagnifyInputReplay() throws {
  guard let path = ProcessInfo.processInfo.environment["PADINK_ZOOM_REPLAY_DIAGNOSTIC"] else { throw XCTSkip("Set PADINK_ZOOM_REPLAY_DIAGNOSTIC to a captured device diagnostic to run this optional replay") }
  struct Trace: Decodable {
   let stage: String, item: UInt64, time: UInt64, sequence: UInt64
   let state: String?, value: Double?, ordinal: UInt64?
  }
  struct Report: Decodable { let traces: [Trace] }
  let source = try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  let injection = source.traces.filter { $0.stage == "touch.inject" && $0.state?.hasPrefix("magnify:") == true }
  let postedIDs = Set(source.traces.filter { $0.stage == "zoom.postInvoked" }.map(\.item))
  let selectedIDs = Set(injection.map(\.item)).intersection(postedIDs).sorted()
  XCTAssertEqual(selectedIDs.map { $0 - (1 << 63) }, [15, 22, 31, 32], "expected four accepted GoodNotes gestures in this evidence")
  var comparisons: [[String: Any]] = []
  for id in selectedIDs {
   let input = injection.filter { $0.item == id }.sorted {
    $0.time == $1.time ? ($0.ordinal ?? 0) < ($1.ordinal ?? 0) : $0.time < $1.time
   }
   guard let first = input.first, let last = input.last else { continue }
   XCTAssertEqual(first.state, "magnify:began"); XCTAssertEqual(input.last?.state, "magnify:ended")
   var row: [String: Any] = ["gestureID": String(id), "gestureSuffix": id - (1 << 63),
    "capturedInputCount": input.count, "capturedInputDurationNs": last.time - first.time,
    "capturedLogDeltas": input.filter { $0.state == "magnify:changed" }.map { $0.value ?? 0 }]
   for continuous in [false, true] {
    let f = Fixture(continuous: continuous), origin = f.now
    var terminalCount: Int?
    for record in input {
     f.advanceTo(origin + record.time - first.time)
     let phase: TouchPhase
     switch record.state {
     case "magnify:began": phase = .began
     case "magnify:changed": phase = .changed
     case "magnify:ended": phase = .ended
     case "magnify:cancelled": phase = .cancelled
     default: return XCTFail("unsupported captured magnify phase")
     }
     guard let sequence = UInt32(exactly: record.sequence) else { return XCTFail("invalid captured sequence") }
     f.send(sequence, phase, delta: Float(record.value ?? 0), id: id - (1 << 63)); f.immediate()
     if phase == .ended || phase == .cancelled { terminalCount = continuous ? f.sink.posts.count : f.sink.commands.count }
    }
    f.drain()
    let afterEnd = (continuous ? f.sink.posts.count : f.sink.commands.count) - (terminalCount ?? 0)
    var output = metrics(f, continuous: continuous); output["postsAfterEnded"] = afterEnd
    if continuous { XCTAssertEqual(afterEnd, 0); XCTAssertTrue(f.sink.commands.isEmpty) }
    XCTAssertTrue(f.rejects.isEmpty); XCTAssertTrue(f.failures.isEmpty); f.assertIdle()
    row[continuous ? "continuous" : "stepped"] = output
   }
   comparisons.append(row)
  }
  try writeComparison("capturedReplay", value: ["diagnostic": path, "gestures": comparisons])
 }
 func testPinchEndedThenOrdinaryScrollKeepsZeroFlagsAndNeverCallsZoom() {
  let f = Fixture(); f.begin(); f.send(2, .changed, delta: 0.05); f.immediate(); f.send(3, .ended); f.drain()
  XCTAssertEqual(f.sink.posts.count, 1)
  for (id, direction): (UInt64, Float) in [(2, 1), (3, -1)] {
   f.send(1, .began, id: id, kind: .scroll)
   f.send(2, .changed, id: id, kind: .scroll, dy: direction * 0.02)
   f.send(3, .ended, id: id, kind: .scroll)
  }
  f.drain(); XCTAssertEqual(f.sink.posts.count, 1); XCTAssertTrue(f.sink.commands.isEmpty)
  XCTAssertEqual(f.events.count, 6); XCTAssertTrue(f.events.allSatisfy { $0.type == .scrollWheel && $0.flags.isEmpty })
  XCTAssertEqual(f.events.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [1, 2, 4, 1, 2, 4])
  XCTAssertLessThan(f.events[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
  XCTAssertGreaterThan(f.events[4].getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
  XCTAssertTrue(f.rejects.isEmpty); XCTAssertNil(f.touch.ownership.active); XCTAssertFalse(f.touch.backend.pressed); f.assertIdle()
 }
}
