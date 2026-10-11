import XCTest
import PadInkCore
@testable import PadInkMacKit

/// E-015 H1: drives the real receive/begin/pump/execute/completion path on virtual time, no Dispatch or sleeps.
/// Origin: investigation/goodnotes-zoom-E015 a29db20 (old D < 180 ms gave D + 180 ms between submissions).
final class ZoomControllerTimingTests: XCTestCase {
 private var context = ZoomActionContext(input: InputContext(attachmentID: UUID(), generation: 1), gestureID: 1 << 63, geometryGeneration: 1, targetRevision: 1)
 private func receive(_ z: ZoomController, _ event: TouchEvent) {
  if event.phase == .began { context = ZoomActionContext(input: context.input, gestureID: event.gestureID, geometryGeneration: event.geometryGeneration, targetRevision: 1) }
  z.receive(event, context: context)
 }

 private let ms: UInt64 = 1_000_000, interval: UInt64 = 180_000_000
 private final class Scheduler {
  struct Job { let deadline: UInt64; let action: () -> Void }
  var now: UInt64 = 0, jobs: [Job] = [], delays: [UInt64] = []
  func enqueue(_ action: @escaping () -> Void) { jobs.append(Job(deadline: now, action: action)) }
  func after(_ delay: UInt64, _ action: @escaping () -> Void) -> (() -> Void) { delays.append(delay); jobs.append(Job(deadline: now + delay, action: action)); return {} }
  /// External input at a fixed virtual time; not a controller timer.
  func at(_ time: UInt64, _ action: @escaping () -> Void) { jobs.append(Job(deadline: time, action: action)) }
  func run() {
   var count = 0
   while let index = jobs.indices.min(by: { jobs[$0].deadline < jobs[$1].deadline }) {
    count += 1; precondition(count < 200, "unexpected rescheduling loop")
    let job = jobs.remove(at: index); now = max(now, job.deadline); job.action()
   }
  }
 }
 private final class Context: ApplicationZoomContext {
  let family = ApplicationFamily.preview
  var capabilities = ApplicationCapabilities()
  let scheduler: Scheduler, duration: UInt64
  var starts: [UInt64] = []
  init(_ scheduler: Scheduler, _ duration: UInt64) { self.scheduler = scheduler; self.duration = duration }
  func execute(_ command: ZoomCommand, permit: ZoomPermit) throws {
   guard permit.current else { throw ZoomFailure.cancelled }
   starts.append(scheduler.now); scheduler.now += duration
  }
 }
 private static func event(_ phase: TouchPhase, _ delta: Float = 0) -> TouchEvent {
  TouchEvent(gestureID: 1 << 63, sequence: 1, timestamp: 0, geometryGeneration: 1, kind: .magnify, phase: phase, x: 0.5, y: 0.5, dx: delta)
 }
 private func make(_ duration: UInt64, origin: UInt64 = 0) -> (ZoomController, Scheduler, Context) {
  let s = Scheduler(); s.now = origin; let c = Context(s, duration)
  let z = ZoomController(clock: { s.now }, enqueueWorker: s.enqueue, enqueueCompletion: s.enqueue, schedule: s.after, probe: { _ in c })
  z.onFailure = { XCTFail("unexpected zoom failure \($0)") }
  return (z, s, c)
 }

 func testShortCommandWaitsOnlyTheRemainingInterval() {
  for origin: UInt64 in [0, 1_000_000_000] {
   for d in [0, 30, 50, 100, 179].map({ $0 * ms }) + [interval - 1] {
    let (z, s, c) = make(d, origin: origin)
    receive(z, Self.event(.began)); self.receive(z, Self.event(.changed, 1)); self.receive(z, Self.event(.ended)); s.run()
    XCTAssertEqual(c.starts, [origin, origin + interval], "D=\(d)")
    XCTAssertEqual(s.delays, d == 0 ? [interval] : [interval - d], "D=\(d)")
   }
  }
 }
 func testCommandAtOrBeyondTheIntervalContinuesRightAfterCompletion() {
  for d in [180, 181, 250].map({ $0 * ms }) {
   let (z, s, c) = make(d)
   receive(z, Self.event(.began)); self.receive(z, Self.event(.changed, 1)); self.receive(z, Self.event(.ended)); s.run()
   XCTAssertEqual(c.starts, [0, d], "D=\(d)"); XCTAssertEqual(s.delays, [], "no timer when the interval has already elapsed")
  }
 }
 func testNoPendingDemandArmsNoTimerAndLaterDemandWaitsOnlyTheRemainder() {
  let (z, s, c) = make(50 * ms)
  receive(z, Self.event(.began)); self.receive(z, Self.event(.changed, 0.15)); s.run()
  XCTAssertEqual(c.starts, [0]); XCTAssertEqual(s.delays, [])
  s.at(100 * ms) { self.receive(z, Self.event(.changed, 0.15)) }; s.at(400 * ms) { self.receive(z, Self.event(.ended)) }; s.run()
  XCTAssertEqual(c.starts, [0, interval]); XCTAssertEqual(s.delays, [80 * ms])
 }
 func testEndDuringWaitSubmitsThePendingStepOnceThenStops() {
  let (z, s, c) = make(50 * ms)
  receive(z, Self.event(.began)); self.receive(z, Self.event(.changed, 1)); s.at(100 * ms) { self.receive(z, Self.event(.ended)) }; s.run()
  XCTAssertEqual(c.starts, [0, interval]); XCTAssertEqual(s.delays, [130 * ms]); XCTAssertTrue(s.jobs.isEmpty)
  receive(z, Self.event(.changed, 1)); s.run()
  XCTAssertEqual(c.starts.count, 2, "an ended gesture accepts no further steps")
 }
 func testCancelDuringWaitFencesTheStaleTimerFromTheNextGesture() {
  let (z, s, c) = make(50 * ms)
  receive(z, Self.event(.began)); self.receive(z, Self.event(.changed, 1))
  s.at(100 * ms) { z.cancel() }
  s.at(110 * ms) { self.receive(z, Self.event(.began)); self.receive(z, Self.event(.changed, 0.15)); self.receive(z, Self.event(.ended)) }
  s.run()
  // The old 230 ms timer fires into the new gesture's ticket and must not submit anything.
  XCTAssertEqual(c.starts, [0, 110 * ms]); XCTAssertEqual(s.delays, [130 * ms])
 }
 func testRepeatedChangesWhileWaitingKeepOneTimerAndTheDemandCap() {
  let (z, s, c) = make(50 * ms)
  receive(z, Self.event(.began)); self.receive(z, Self.event(.changed, 1))
  for t: UInt64 in [60, 90, 120] { s.at(t * ms) { self.receive(z, Self.event(.changed, 1)) } }
  s.at(130 * ms) { self.receive(z, Self.event(.ended)) }
  s.run()
  XCTAssertEqual(c.starts, [0, interval, 2 * interval], "demand stays capped at two pending steps, one submission per interval")
  XCTAssertEqual(s.delays, [130 * ms, 130 * ms], "one timer per wait, never duplicated by extra changes")
 }
}
