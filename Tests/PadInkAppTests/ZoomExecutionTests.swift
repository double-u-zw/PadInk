import XCTest
import AppKit
import PadInkCore
@testable import PadInkMacKit

/// Real Coordinator ingress -> ownership -> backend -> controller. Only OS side effects and
/// executors are replaced. The clock/stamps/geometry are valid; no sleeps or settle loops.
final class ZoomExecutionTests: XCTestCase {
 private final class Sink: ApplicationZoomContext {
  let family = ApplicationFamily.goodnotes
  var capabilities = ApplicationCapabilities()
  var calls: [ZoomActionContext] = [], jobs: [UUID] = []
  var beforeClaim: (ZoomPermit) -> Void = { _ in }, duringCall: (ZoomPermit) -> Void = { _ in }
  var secondCall = false
  func execute(_ command: ZoomCommand, permit: ZoomPermit) throws {
   let event = try GoodnotesPublicZoom.event(command, at: CGPoint(x: 100, y: 100)) // preparation
   beforeClaim(permit)
   // Same final post boundary used by ApplicationZoomTarget.execute in the product.
   try ApplicationZoomTarget.post(event, permit: permit) { _ in
    calls.append(permit.context!); jobs.append(permit.jobID!); duringCall(permit)
   }
   if secondCall { try ApplicationZoomTarget.post(event, permit: permit) { _ in XCTFail("cancelled permit granted another call") } }
  }
 }
 private final class Fixture {
  struct Timer { let deadline: UInt64; let fire: () -> Void }
  var now: UInt64 = 1_000_000_000, workers: [() -> Void] = [], completions: [() -> Void] = [], timers: [Timer] = []
  var input = InputContext(attachmentID: UUID(), generation: 7), revision: UInt64 = 10
  let diagnostics = Diagnostics(), sink = Sink()
  var events: [CGEvent] = [], pencilEvents: [CGEventType] = [], stages: [(UUID, UUID?, String)] = [], probes: [ZoomActionContext] = []
  var probeError: Error?
  var zoom: ZoomController!, touch: TouchInputPipeline!, pencil: PencilInputPipeline!
  init() {
   zoom = ZoomController(clock: { self.now }, enqueueWorker: { self.workers.append($0) }, enqueueCompletion: { self.completions.append($0) },
    schedule: { delay, fire in self.timers.append(Timer(deadline: self.now + delay, fire: fire)); return {} },
    probe: { permit in self.probes.append(permit.context!); if let error = self.probeError { throw error }; return self.sink })
   zoom.onStage = { c, job, stage, _ in self.stages.append((c.actionID, job, stage)) }
   let b = PointerInjectionBackend { self.events.append($0) }; b.displayBounds = CGRect(x: 0, y: 0, width: 500, height: 500)
   touch = TouchInputPipeline(backend: b, diagnostics: diagnostics)
   let pb = PencilInjectionBackend(diagnostics: diagnostics, postEvent: { self.pencilEvents.append($0.type) })
   pb.displayBounds = b.displayBounds
   pencil = PencilInputPipeline(backend: pb, diagnostics: diagnostics)
   MacCoordinator.connectInputs(pencil: pencil, touch: touch, zoom: zoom)
   touch.attach(context: input); pencil.attach(generation: UInt64(input.generation))
   geometry(1); settings(true)
  }
  func frame(_ type: MessageType, _ payload: Data, input supplied: InputContext? = nil, stamp: UInt64? = nil) {
   let c = supplied ?? input
   let f = Frame(type: type, generation: c.generation, sequence: 1, timestamp: now, payload: payload)
   do { try MacCoordinator.receiveInput(f, stamp: ReceiveStamp(localTime: stamp ?? now), now: now, input: c, targetRevision: revision, target: nil, pencil: pencil, touch: touch) }
   catch { XCTFail("fixture payload rejected: \(error)") }
  }
  func send(_ id: UInt64, _ sequence: UInt32, _ phase: TouchPhase, kind: TouchKind = .magnify, delta: Float = 0, stamp: UInt64? = nil, input: InputContext? = nil) {
   let e = TouchEvent(gestureID: (UInt64(1) << 63) + id, sequence: sequence, timestamp: now + UInt64(sequence), geometryGeneration: 1, kind: kind, phase: phase, x: 0.5, y: 0.5, dx: delta)
   frame(kind.message, try! e.encoded(), input: input, stamp: stamp)
  }
  func tail(_ id: UInt64 = 1, delta: Float = 0.15) {
   send(id, 1, .began); send(id, 2, .changed, delta: delta); send(id, 3, .ended)
   XCTAssertNil(touch.ownership.active); XCTAssertNil(touch.ownership.last)
  }
  func geometry(_ generation: UInt32, ready: Bool = true, input: InputContext? = nil) {
   frame(.presentedGeometry, PresentedGeometry(generation: generation, ready: ready, orientation: 4, videoWidth: 500, videoHeight: 500).encoded(), input: input)
  }
  func cancel(_ id: UInt64 = 1, input: InputContext? = nil) { frame(.inputCancel, GestureNotice(gestureID: (UInt64(1) << 63) + id, reason: .appBackground).encoded(), input: input) }
  func settings(_ enabled: Bool) { frame(.inputSettings, InputSettings(touchEnabled: enabled).encoded()) }
  func target(_ revision: UInt64, input: InputContext? = nil) { MacCoordinator.targetChanged(to: revision, input: input ?? self.input, touch: touch) }
  func attachment(_ event: AttachmentEvent, input: InputContext? = nil) { MacCoordinator.inputAttachmentEvent(event, input: input ?? self.input, pencil: pencil, touch: touch) }
  func pencilBegin(stamp: UInt64? = nil) {
   let s = PencilSample(stroke: 1, sequence: 1, timestamp: now, x: 0.5, y: 0.5, pressure: 0.5, altitude: 1, azimuth: 0, phase: .begin, geometryGeneration: 1)
   frame(.pencil, try! PencilBatch([s]).encoded(), stamp: stamp)
  }
  func worker() { XCTAssertEqual(workers.count, 1, "one occupied physical job"); guard !workers.isEmpty else { return }; workers.removeFirst()() }
  @discardableResult func complete() -> (() -> Void)? { XCTAssertEqual(completions.count, 1); guard !completions.isEmpty else { return nil }; let c = completions.removeFirst(); c(); return c }
  func probe() { worker(); complete() }
  func drain() {
   for _ in 0..<30 {
    if !workers.isEmpty { worker() }
    else if !completions.isEmpty { complete() }
    else if !timers.isEmpty { let t = timers.removeFirst(); now = max(now, t.deadline); t.fire() }
    else { return }
   }
   XCTFail("unbounded scheduler")
  }
 }
 func testPositiveControlNormalEndedDrainsFiniteDemandThroughRealIngress() {
  let f = Fixture(); f.tail(delta: 1); f.drain()
  XCTAssertEqual(f.sink.calls.count, 2); XCTAssertEqual(f.stages.filter { $0.2 == "claimed" }.count, 2)
  XCTAssertEqual(f.stages.filter { $0.2 == "postInvoked" }.count, 2)
  XCTAssertEqual(f.stages.filter { $0.2 == "commandReturned" }.count, 2)
  XCTAssertEqual(Set(f.sink.calls.map(\.actionID)).count, 1); XCTAssertEqual(Set(f.sink.jobs).count, 2)
 }
 func testAcceptedPointerRevokesEndedTailAndWorks() {
  let f = Fixture(); f.tail(); f.send(2, 1, .began, kind: .pointer); f.drain()
  XCTAssertEqual(f.sink.calls.count, 0, "accepted pointer must revoke ended zoom tail")
  XCTAssertEqual(f.events.map(\.type), [.leftMouseDown]); XCTAssertTrue(f.touch.backend.pressed)
 }
 func testAcceptedScrollRevokesEndedTailAndWorks() {
  let f = Fixture(); f.tail(); f.send(2, 1, .began, kind: .scroll); f.drain()
  XCTAssertEqual(f.sink.calls.count, 0); XCTAssertEqual(f.events.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [1])
 }
 func testAcceptedPinchReplacesEndedTailWithItsOwnContext() {
  let f = Fixture(); f.tail(); f.tail(2); XCTAssertEqual(f.workers.count, 1); f.drain()
  XCTAssertEqual(f.sink.calls.map(\.gestureID), [(UInt64(1) << 63) + 2]); XCTAssertEqual(f.probes.map(\.gestureID), [(UInt64(1) << 63) + 2])
 }
 func testGeometryInvalidationAfterEndedRevokesTail() {
  for ready in [true, false] { let f = Fixture(); f.tail(); f.geometry(ready ? 2 : 1, ready: ready); f.drain(); XCTAssertTrue(f.sink.calls.isEmpty) }
 }
 func testSameAppWindowTargetRevisionAfterEndedRevokesTail() {
  let f = Fixture(); f.tail(); f.target(11); f.drain(); XCTAssertTrue(f.sink.calls.isEmpty)
 }
 func testMatchingExplicitInputCancelAfterEndedRevokesTail() {
  let f = Fixture(); f.tail(); f.cancel(); f.drain(); XCTAssertTrue(f.sink.calls.isEmpty)
 }
 func testAttachmentDisconnectAfterEndedRevokesTail() {
  let f = Fixture(); f.tail(); f.attachment(.ended(.closedLocally(.userDisconnect))); f.drain(); XCTAssertTrue(f.sink.calls.isEmpty)
 }
 func testRelevantTouchSettingChangeAfterEndedRevokesTail() {
  let f = Fixture(); f.tail(); f.settings(false); f.drain(); XCTAssertTrue(f.sink.calls.isEmpty)
 }
 func testAcceptedPencilTakeoverAfterEndedDoesNotWaitForWorker() {
  let f = Fixture(); f.tail(); f.pencilBegin(); XCTAssertTrue(f.pencil.backend.active); XCTAssertEqual(f.workers.count, 1)
  XCTAssertEqual(f.pencilEvents, [.tabletProximity, .leftMouseDown]); f.drain(); XCTAssertTrue(f.sink.calls.isEmpty)
 }
 func testRejectedPencilBeginDoesNotCancelEndedTail() {
  let f = Fixture(); f.tail(); f.pencilBegin(stamp: f.now - 100_000_001); f.drain(); XCTAssertEqual(f.sink.calls.count, 1); XCTAssertFalse(f.pencil.backend.active)
 }
 func testRejectedStaleDuplicateAndWrongGeometryBeganPreserveActiveZoom() {
  for mode in 0..<3 {
   let f = Fixture(); f.send(1,1,.began); f.send(1,2,.changed,delta: 0.15)
   if mode == 0 { f.send(2,1,.began,kind: .pointer,stamp: f.now - 100_000_001) }
   else if mode == 1 { f.send(1,1,.began,kind: .pointer) }
   else {
    let e = TouchEvent(gestureID: (1<<63)+2,sequence: 1,timestamp: f.now,geometryGeneration: 2,kind: .pointer,phase: .began,x: 0.5,y: 0.5)
    f.frame(.pointer,try! e.encoded())
   }
   XCTAssertEqual(f.touch.ownership.active?.gestureID,(1<<63)+1)
   f.send(1,3,.ended); f.drain(); XCTAssertEqual(f.sink.calls.count,1); XCTAssertTrue(f.events.isEmpty)
  }
 }
 func testStaleDuplicateAndWrongAttachmentBeganCannotCancelEndedTail() {
  for mode in 0..<3 {
   let f = Fixture(); f.tail()
   if mode == 0 { f.send(2, 1, .began, kind: .pointer, stamp: f.now - 100_000_001) }
   else if mode == 1 { f.send(1, 1, .began, kind: .pointer) }
   else { f.send(2, 1, .began, kind: .pointer, input: InputContext(attachmentID: UUID(), generation: f.input.generation)) }
   f.drain(); XCTAssertEqual(f.sink.calls.count, 1); XCTAssertTrue(f.events.isEmpty)
  }
 }
 func testOldAttachmentAndOldGestureInputCancelDoNotKillNewAction() {
  for oldAttachment in [false, true] {
   let f = Fixture(); f.tail(2); f.cancel(oldAttachment ? 2 : 1, input: oldAttachment ? InputContext(attachmentID: UUID(), generation: f.input.generation) : nil)
   f.drain(); XCTAssertEqual(f.sink.calls.count, 1)
  }
 }
 func testSameGeometryRepeatAndOldAttachmentGeometryPreserveTail() {
  let f = Fixture(); f.tail(); f.geometry(1); f.geometry(2, input: InputContext(attachmentID: UUID(), generation: f.input.generation)); f.drain(); XCTAssertEqual(f.sink.calls.count, 1)
 }
 func testSameOrOlderTargetRevisionAndOldAttachmentTargetPreserveTail() {
  let f = Fixture(); f.tail(); f.target(10); f.target(9); f.target(11, input: InputContext(attachmentID: UUID(), generation: f.input.generation)); f.drain(); XCTAssertEqual(f.sink.calls.count, 1)
 }
 func testBOnlyRecoveryPreservesControlTail() {
  let f = Fixture(); f.tail(); f.attachment(.videoRebuildNeeded(.connectionFailed)); f.attachment(.videoRebuilt); f.drain(); XCTAssertEqual(f.sink.calls.count, 1)
 }
 func testDiagnosticsSnapshotAndRepeatedEnabledSettingDoNotCancelInput() {
  let f = Fixture(); f.tail(); _ = f.diagnostics.report(); f.settings(true); f.drain(); XCTAssertEqual(f.sink.calls.count, 1)
 }
 func testStaleProbeCompletionOnlyRetiresOwnJobThenProbesNewIdentity() {
  let f = Fixture(); f.tail(); f.worker() // result is waiting on the input queue
  f.tail(2); XCTAssertTrue(f.workers.isEmpty)
  f.complete(); XCTAssertEqual(f.workers.count, 1); f.drain()
  XCTAssertEqual(f.probes.map(\.gestureID), [(UInt64(1) << 63) + 1, (UInt64(1) << 63) + 2]); XCTAssertEqual(f.sink.calls.map(\.gestureID), [(UInt64(1) << 63) + 2])
 }
 func testStaleExecuteCompletionDoesNotReleaseNewPointerOrApplyOldStatus() {
  let f = Fixture(); var submitted = 0; f.zoom.onSubmitted = { _ in submitted += 1 }
  f.tail(); f.probe(); f.worker(); f.send(2, 1, .began, kind: .pointer); f.complete()
  XCTAssertEqual(submitted, 0); XCTAssertTrue(f.touch.backend.pressed); XCTAssertEqual(f.events.map(\.type), [.leftMouseDown])
 }
 func testOldCompletionCannotRetireNewJobOrClearNewDemand() {
  let f = Fixture(); f.tail(); f.probe(); f.worker(); f.tail(2, delta: 1)
  let old = f.complete()!; XCTAssertEqual(f.workers.count, 1)
  old(); XCTAssertEqual(f.workers.count, 1, "duplicate old completion cannot retire a new job")
  f.drain(); XCTAssertEqual(f.sink.calls.map(\.gestureID), [(UInt64(1) << 63) + 1, (UInt64(1) << 63) + 2, (UInt64(1) << 63) + 2])
 }
 func testStaleTimerCannotClearNewScheduledFlagOrSubmitOldDemand() {
  let f = Fixture(); f.tail(delta: 1); f.probe(); f.worker(); f.complete(); let old = f.timers.removeFirst()
  f.tail(2, delta: 1); f.probe(); f.worker(); f.complete()
  XCTAssertEqual(f.timers.count, 1); old.fire(); XCTAssertEqual(f.timers.count, 1); XCTAssertTrue(f.workers.isEmpty)
  f.drain(); XCTAssertEqual(f.sink.calls.map(\.gestureID), [(UInt64(1) << 63) + 1, (UInt64(1) << 63) + 2, (UInt64(1) << 63) + 2])
 }
 func testRepeatedReplacementKeepsOneWorkerAndOneLatestAction() {
  let f = Fixture()
  for id: UInt64 in 1...100 { f.tail(id); f.cancel(id) }
  XCTAssertEqual(f.workers.count, 1, "cancelling an action cannot retire a physical job")
  f.tail(101); XCTAssertEqual(f.workers.count, 1); f.drain(); XCTAssertEqual(f.probes.count, 1); XCTAssertEqual(f.sink.calls.count, 1)
 }
 func testCancelBeforeFinalClaimAfterPreparationPostsNothing() {
  let f = Fixture(); f.tail(delta: 1); f.probe()
  f.sink.beforeClaim = { _ in f.cancel() } // deterministic test-only barrier after preparation
  f.worker(); f.complete(); f.drain()
  XCTAssertTrue(f.sink.calls.isEmpty); XCTAssertTrue(f.stages.filter { $0.2 == "claimed" }.isEmpty)
 }
 func testClaimBeforeCancelAllowsOneCallAndNoNextOldCall() {
  let f = Fixture(); f.tail(delta: 1); f.probe()
  f.sink.duringCall = { _ in f.cancel() }; f.sink.secondCall = true
  f.worker(); f.complete(); f.drain()
  XCTAssertEqual(f.sink.calls.count, 1); XCTAssertEqual(f.stages.filter { $0.2 == "claimed" }.count, 1); XCTAssertTrue(f.workers.isEmpty)
 }
 func testPointerReleaseBeforeNewScrollAndRepeatedCancelDoesNotDoubleRelease() {
  let f = Fixture(); f.send(1, 1, .began, kind: .pointer); f.send(2, 1, .began, kind: .scroll)
  XCTAssertEqual(f.events.map(\.type), [.leftMouseDown, .leftMouseUp, .scrollWheel])
  f.touch.cancel(.targetChanged); f.touch.cancel(.targetChanged)
  XCTAssertEqual(f.events.filter { $0.type == .leftMouseUp }.count, 1)
  XCTAssertEqual(f.events.filter { $0.type == .scrollWheel }.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [1,8])
 }
 func testAcceptedPencilReleasesActualTouchBeforeItsDownAndOldJobCompletionCannotReleaseIt() {
  let f = Fixture(); var order: [String] = []
  let pointer = PointerInjectionBackend { order.append($0.type == .leftMouseDown ? "touchDown" : "touchUp") }
  pointer.displayBounds = CGRect(x: 0,y: 0,width: 500,height: 500)
  f.touch = TouchInputPipeline(backend: pointer, diagnostics: f.diagnostics)
  let backend = PencilInjectionBackend(diagnostics: f.diagnostics, postEvent: { order.append(String($0.type.rawValue)) })
  backend.displayBounds = pointer.displayBounds; f.pencil = PencilInputPipeline(backend: backend, diagnostics: f.diagnostics)
  MacCoordinator.connectInputs(pencil: f.pencil, touch: f.touch, zoom: f.zoom)
  f.touch.attach(context: f.input); f.pencil.attach(generation: UInt64(f.input.generation)); f.geometry(1); f.settings(true)
  f.tail(); f.worker(); f.send(2, 1, .began, kind: .pointer); f.pencilBegin()
  XCTAssertEqual(order, ["touchDown", "touchUp", String(CGEventType.tabletProximity.rawValue), String(CGEventType.leftMouseDown.rawValue)])
  f.complete(); XCTAssertTrue(f.pencil.backend.active); XCTAssertEqual(order.count, 4)
  f.pencil.cancelAll(.transportLost); f.pencil.cancelAll(.transportLost)
  XCTAssertEqual(order.suffix(2), [String(CGEventType.leftMouseUp.rawValue), String(CGEventType.tabletProximity.rawValue)])
  XCTAssertEqual(order.count, 6)
 }
 func testGeometryTargetAndExplicitCancelRevokeEndedTimerDrain() {
  for mode in 0..<3 {
   let f = Fixture(); f.tail(delta: 1); f.probe(); f.worker(); f.complete()
   XCTAssertEqual(f.sink.calls.count,1); XCTAssertEqual(f.timers.count,1); XCTAssertNil(f.touch.ownership.active)
   if mode == 0 { f.geometry(2) } else if mode == 1 { f.target(11) } else { f.cancel() }
   f.drain(); XCTAssertEqual(f.sink.calls.count,1,"environment invalidation must revoke a scheduled ended drain")
  }
 }
 func testOldProbeFailureCannotApplyFallbackToNewAction() {
  let f = Fixture(); var failures: [String] = []; f.zoom.onFailure = { failures.append($0) }
  f.tail(); f.probeError = ZoomFailure.automationDenied; f.worker()
  f.tail(2); f.probeError = nil; f.complete(); f.drain()
  XCTAssertTrue(failures.isEmpty); XCTAssertEqual(f.sink.calls.map(\.gestureID),[(1<<63)+2])
 }
 func testOldAttachmentDisconnectAndCancelCannotAffectReplacementWithSameGenerationAndGesture() {
  let f = Fixture(); f.tail(); f.worker(); let old = f.input
  f.input = InputContext(attachmentID: UUID(),generation: old.generation)
  f.touch.attach(context: f.input); f.pencil.attach(generation: UInt64(f.input.generation)); f.geometry(1); f.settings(true); f.tail()
  f.attachment(.ended(.replaced),input: old); f.cancel(input: old); f.target(11,input: old)
  f.complete(); f.drain(); XCTAssertEqual(f.sink.calls.map(\.input),[f.input])
 }
 func testRepeatedReplacementWhileProbeCompletionPendingRemainsBounded() {
  let f = Fixture(); f.tail(); f.worker()
  for id: UInt64 in 2...101 { f.tail(id); f.cancel(id) }
  f.tail(102); XCTAssertTrue(f.workers.isEmpty); XCTAssertEqual(f.completions.count,1)
  f.drain(); XCTAssertEqual(f.probes.count,2); XCTAssertEqual(f.sink.calls.map(\.gestureID),[(1<<63)+102])
 }
 func testScrollCancellationPrecedesPencilProximityAndDown() {
  let f = Fixture(); f.send(1,1,.began,kind: .scroll)
  f.pencil.onAcceptedBegin = {
   f.touch.pencilTakeover()
   XCTAssertEqual(f.events.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) },[1,8])
   XCTAssertTrue(f.pencilEvents.isEmpty,"release must precede Pencil proximity/down")
  }
  f.pencilBegin(); XCTAssertEqual(f.pencilEvents,[.tabletProximity,.leftMouseDown])
  f.touch.cancel(.pencilPreempted); XCTAssertEqual(f.events.count,2)
 }
 func testCancelledContactRevokesQueuedCommand() {
  let f = Fixture(); f.send(1,1,.began); f.send(1,2,.changed,delta: 1); f.send(1,3,.cancelled); f.drain(); XCTAssertTrue(f.sink.calls.isEmpty)
 }
 func testResetHasUniqueIdentityAndTouchSettingDoesNotCancelIt() {
  let f = Fixture(); f.touch.resetZoom(targetRevision: f.revision, target: nil); f.settings(false)
  // Sink's public Goodnotes helper cannot reset, so test the action/probe identity without posting.
  f.worker(); XCTAssertNil(f.probes.first?.gestureID); XCTAssertEqual(f.probes.first?.input, f.input)
  f.target(11); f.complete(); XCTAssertTrue(f.workers.isEmpty)
 }
}
