import XCTest
import AppKit
import PadInkCore
@testable import PadInkMacKit
@testable import PadInkPadKit

/// The Mac Pencil path end to end: wire batch -> ownership -> backend -> CGEvents (sink).
final class PencilPipelineTests: XCTestCase {
 private var events = [CGEvent](), rejects = [GestureNotice](), deadlines = [UInt64?]()
 private func t(_ ms: Int) -> UInt64 { UInt64(ms) * 1_000_000 }
 private func pipeline() -> PencilInputPipeline {
  let b = PencilInjectionBackend(diagnostics: Diagnostics(), now: { [unowned self] in self.now }, postEvent: { [unowned self] in self.events.append($0) })
  b.displayBounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
  let p = PencilInputPipeline(backend: b, diagnostics: Diagnostics())
  p.sendReject = { [unowned self] in self.rejects.append($0) }; p.scheduleDeadline = { [unowned self] in self.deadlines.append($0) }
  p.attach(generation: 1); p.presentedGeometry(PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 2360, videoHeight: 1534))
  return p
 }
 private var now: UInt64 = 0
 private func batch(_ seqs: ClosedRange<UInt64>, begin: Bool = false, end: Bool = false, x: Float = 0.5) -> PencilBatch {
  try! PencilBatch(seqs.map { s in PencilSample(stroke: 1, sequence: s, timestamp: s * 4_000_000, x: x, y: 0.5, pressure: 0.6, altitude: 1, azimuth: 0, phase: (begin && s == seqs.lowerBound) ? .begin : (end && s == seqs.upperBound) ? .end : .move, geometryGeneration: 1) })
 }
 private var types: [CGEventType] { events.map(\.type) }

 func testStrokeProducesBaselineEventSequenceAndArmsDeadline() {
  let p = pipeline()
  now = t(1); p.pencil(batch(1...1, begin: true), stamp: ReceiveStamp(localTime: t(0)), now: t(1))
  now = t(10); p.pencil(batch(2...4), stamp: ReceiveStamp(localTime: t(9)), now: t(10))
  now = t(20); p.pencil(batch(5...5, end: true), stamp: ReceiveStamp(localTime: t(19)), now: t(20))
  XCTAssertEqual(types, [.tabletProximity, .leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseDragged, .leftMouseUp, .tabletProximity])
  XCTAssertEqual(deadlines.compactMap { $0 }.first, t(1000)); XCTAssertNil(deadlines.last!, "deadline cleared after the stroke ends")
  XCTAssertTrue(rejects.isEmpty)
 }

 /// Fault row 2 at the event level: the stale batch is never posted; the stroke is released once.
 func testStaleBatchIsNotPostedAndStrokeIsReleasedOnce() {
  let p = pipeline()
  now = t(1); p.pencil(batch(1...2, begin: true), stamp: ReceiveStamp(localTime: t(0)), now: t(1))
  let before = events.count
  now = t(300); p.pencil(batch(3...5, x: 0.9), stamp: ReceiveStamp(localTime: t(150)), now: t(300))
  XCTAssertEqual(Array(types.dropFirst(before)), [.leftMouseUp, .tabletProximity])
  XCTAssertEqual(events[before].location.x, 500, accuracy: 0.01, "released at the last injected point, not the stale one")
  XCTAssertEqual(rejects, [GestureNotice(gestureID: 1, reason: .staleSample)])
  now = t(310); p.pencil(batch(6...6, end: true), stamp: ReceiveStamp(localTime: t(309)), now: t(310))
  XCTAssertEqual(events.count, before + 2)
 }

 /// Fault row 6 at the event level: the timer at the published deadline releases a stationary pencil.
 func testTimerAtDeadlineReleasesStationaryPencil() {
  let p = pipeline()
  now = t(1); p.pencil(batch(1...1, begin: true), stamp: ReceiveStamp(localTime: t(0)), now: t(1))
  let deadline = deadlines.compactMap { $0 }.last!
  now = deadline; p.timer(now: deadline)
  XCTAssertEqual(Array(types.suffix(2)), [.leftMouseUp, .tabletProximity])
  XCTAssertEqual(rejects, [GestureNotice(gestureID: 1, reason: .gestureTimeout)])
  p.timer(now: deadline + 1); XCTAssertEqual(rejects.count, 1)
 }

 /// Fault rows 5 and 7.
 func testTargetChangeKeepsSessionAndTransportLossRefusesUntilNextAttach() {
  let p = pipeline()
  now = t(1); p.pencil(batch(1...1, begin: true), stamp: ReceiveStamp(localTime: t(0)), now: t(1))
  p.cancelAll(.targetChanged)
  XCTAssertEqual(Array(types.suffix(2)), [.leftMouseUp, .tabletProximity]); XCTAssertEqual(rejects.last?.reason, .targetChanged)
  XCTAssertEqual(p.generation, 1, "session kept")
  p.detach(); let count = events.count
  now = t(50); p.pencil(batch(1...1, begin: true), stamp: ReceiveStamp(localTime: t(49)), now: t(50))
  XCTAssertEqual(events.count, count, "nothing is posted between attachments")
 }

 func testBackendSequenceRejectionReleasesWithoutPartialEvents() {
  let p = pipeline()
  now = t(1); p.pencil(batch(1...1, begin: true), stamp: ReceiveStamp(localTime: t(0)), now: t(1))
  let count = events.count
  now = t(5); p.pencil(batch(3...4), stamp: ReceiveStamp(localTime: t(4)), now: t(5)) // gap: ownership passes, backend rejects
  XCTAssertEqual(Array(types.dropFirst(count)), [.leftMouseUp, .tabletProximity])
  XCTAssertEqual(rejects.last?.reason, .protocolViolation)
 }
}

/// Review of 71bdd94: the reviewer's input-pipeline probe as regression tests (event sink only).
final class PencilPipelineReviewTests: XCTestCase {
 private var types = [CGEventType](), rejects = [GestureNotice]()
 private func make() -> (PencilInputPipeline, PencilInjectionBackend) {
  let b = PencilInjectionBackend(diagnostics: Diagnostics(), now: { 10_000_000 }, postEvent: { [unowned self] in self.types.append($0.type) })
  let p = PencilInputPipeline(backend: b, diagnostics: Diagnostics()); p.sendReject = { [unowned self] in self.rejects.append($0) }
  return (p, b)
 }
 private func ready(_ p: PencilInputPipeline, _ g: UInt64) { p.attach(generation: g); p.presentedGeometry(PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 1000, videoHeight: 500)) }
 private func send(_ p: PencilInputPipeline, _ seq: UInt64, _ phase: PencilPhase) {
  p.pencil(try! PencilBatch([PencilSample(stroke: 1, sequence: seq, timestamp: seq * 1_000_000, x: 0.5, y: 0.5, pressure: 0.5, altitude: 1, azimuth: 0, phase: phase, geometryGeneration: 1)]), stamp: ReceiveStamp(localTime: 10_000_000), now: 10_000_000)
 }
 /// P1 #1: begin(1) then end(3): the backend rejects the gap; the pen must come up and the iPad be told.
 func testInvalidTerminalLeavesNothingPressed() {
  let (p, b) = make(); ready(p, 1); send(p, 1, .begin)
  let before = types.count
  send(p, 3, .end)
  XCTAssertFalse(b.active); XCTAssertNil(p.ownership.active); XCTAssertNil(p.ownership.nextDeadline)
  XCTAssertEqual(Array(types.dropFirst(before)), [.leftMouseUp, .tabletProximity])
  XCTAssertEqual(rejects.map(\.reason), [.protocolViolation])
 }
 /// P1 #3: gesture 1 completed in generation 1; after re-attach, a new gesture 1 must be written.
 func testRestartedGestureIDsAreWrittenInTheNextGeneration() {
  let (p, b) = make(); ready(p, 1); send(p, 1, .begin); send(p, 2, .end)
  p.detach(); ready(p, 2)
  let before = types.count
  send(p, 1, .begin)
  XCTAssertTrue(b.active); XCTAssertEqual(Array(types.dropFirst(before)), [.tabletProximity, .leftMouseDown])
 }
}

final class VideoSenderTests: XCTestCase {
 private func frame(_ id: UInt64, key: Bool = false) -> VideoFrame { VideoFrame(generation: 1, id: id, captureTime: id, key: key, avcc: Data([0, 0, 0, 1, key ? 0x65 : 0x41])) }
 func testOneFrameInFlightBacklogFlagAndClear() {
  let s = VideoSender(diagnostics: Diagnostics()); var sent = [(MessageType, (Error?) -> Void)](); var cleared = 0
  s.send = { type, _, _, completion in sent.append((type, completion)); return true }; s.onBacklogCleared = { cleared += 1 }
  s.push(VideoConfig(generation: 1, width: 2, height: 2, sps: Data([1]), pps: Data([2])), frame(1, key: true))
  XCTAssertEqual(sent.map(\.0), [.videoConfig, .videoFrame]); XCTAssertFalse(s.isBacklogged)
  s.push(nil, frame(2)); XCTAssertEqual(sent.count, 2, "second frame waits"); XCTAssertTrue(s.isBacklogged, "skip before encode now")
  sent[1].1(nil); XCTAssertEqual(sent.map(\.0).last, .videoFrame); XCTAssertFalse(s.isBacklogged); XCTAssertEqual(cleared, 1)
 }
 func testOverflowDropsGOPAndRequestsKeyframeAsLastRung() {
  let s = VideoSender(diagnostics: Diagnostics()); var keyframes = 0
  s.send = { _, _, _, _ in true }; s.requestKeyframe = { keyframes += 1 }
  s.push(nil, frame(1, key: true)); s.push(nil, frame(2)); s.push(nil, frame(3)); s.push(nil, frame(4))
  XCTAssertEqual(keyframes, 1); XCTAssertEqual(s.queuedFrames, 0)
 }
 func testResetIgnoresLateCompletionOfOldEpoch() {
  let s = VideoSender(diagnostics: Diagnostics()); var completions = [(Error?) -> Void](); var sends = 0
  s.send = { _, _, _, c in sends += 1; completions.append(c); return true }
  s.push(nil, frame(1, key: true)); s.reset(); s.push(nil, frame(2, key: true))
  completions[0](nil); XCTAssertEqual(sends, 2, "old completion does not start another send")
 }
}

final class ProvisioningProfileTests: XCTestCase {
 func testExpiryIsReadFromEmbeddedPlist() throws {
  let date = Date(timeIntervalSince1970: 1_790_000_000)
  let plist = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": date, "Name": "iOS Team Provisioning Profile"], format: .xml, options: 0)
  let cms = Data([0x30, 0x82, 0x01, 0x02]) + plist + Data([0xa0, 0x82, 0x00])
  XCTAssertEqual(ProvisioningProfile.expiry(from: cms), date)
  XCTAssertNil(ProvisioningProfile.expiry(from: Data([1, 2, 3])))
 }
 func testReminderStartsThreeDaysBefore() {
  let now = Date(timeIntervalSince1970: 1_000_000)
  XCTAssertNil(ProvisioningProfile.reminder(expiry: 0, now: now))
  XCTAssertNil(ProvisioningProfile.reminder(expiry: UInt64(1_000_000 + 3 * 86_400), now: now))
  XCTAssertNotNil(ProvisioningProfile.reminder(expiry: UInt64(1_000_000 + 3 * 86_400 - 1), now: now))
  XCTAssertTrue(ProvisioningProfile.reminder(expiry: 999_000, now: now)!.contains("已过期"))
  XCTAssertEqual(MacCoordinator.signingWarning(expiry: UInt64(1_000_000 + 86_400), now: now) != nil, true)
 }
}
