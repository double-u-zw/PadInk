import XCTest
@testable import PadInkCore

/// Deterministic clock in milliseconds. Fault rows refer to docs/ARCHITECTURE.md §5.
final class AttachmentLivenessTests: XCTestCase {
 private let ms: UInt64 = 1_000_000
 private func at(_ t: Int) -> UInt64 { UInt64(t) * ms }

 /// Drives A heartbeats every second up to `end`, as a healthy control connection would.
 private func heartbeatsOnA(_ l: inout AttachmentLiveness, from: Int, to end: Int) {
  for t in stride(from: from, through: end, by: 1000) { l.received(on: .controlInput, now: at(t)) }
 }

 /// Reviewer's case: video keeps streaming slowly, but B heartbeats sit behind large frames
 /// for 5 s. This is congestion, never death, and never cancels input.
 func testFaultRow1_VideoStreamingWithDelayedHeartbeatIsCongestionNotDeath() {
  var l = AttachmentLiveness(now: 0)
  heartbeatsOnA(&l, from: 0, to: 6000)
  for t in stride(from: 0, through: 6000, by: 100) { l.videoSendQueue(queuedBytes: 4 << 20, drained: true, now: at(t)) } // draining, but queue large
  // No bytes from the iPad on B for 5 s (its heartbeat acks are delayed / queued).
  l.received(on: .video, now: at(1000))
  let health = l.evaluate(now: at(6000))
  XCTAssertEqual(health, .videoCongested)
  XCTAssertFalse(health.cancelsInput)
 }

 func testFaultRow1_QueueNotDrainingBrieflyIsCongestionAndRecovers() {
  var l = AttachmentLiveness(now: 0)
  l.videoSendQueue(queuedBytes: 200_000, drained: false, now: at(0))
  heartbeatsOnA(&l, from: 0, to: 2000); l.received(on: .video, now: at(2000))
  XCTAssertEqual(l.evaluate(now: at(300)), .videoCongested)
  l.videoSendQueue(queuedBytes: 0, drained: true, now: at(2000))
  XCTAssertEqual(l.evaluate(now: at(2000)), .healthy)
 }

 func testFaultRow7b_VideoSendStalledLongRebuildsVideoOnlyAndInputSurvives() {
  var l = AttachmentLiveness(now: 0)
  l.videoSendQueue(queuedBytes: 3 << 20, drained: false, now: at(0))
  heartbeatsOnA(&l, from: 0, to: 11000)
  for t in stride(from: 0, through: 11000, by: 1000) { l.received(on: .video, now: at(t)) } // iPad still talks on B
  XCTAssertEqual(l.evaluate(now: at(9000)), .videoCongested)
  let health = l.evaluate(now: at(10_001))
  XCTAssertEqual(health, .rebuildVideo(.sendStalled)); XCTAssertFalse(health.cancelsInput)
  l.videoRebuilt(now: at(10_001))
  XCTAssertEqual(l.evaluate(now: at(10_500)), .healthy)
 }

 func testFaultRow7b_VideoSilentFromIPadLongRebuildsVideoOnly() {
  var l = AttachmentLiveness(now: 0)
  heartbeatsOnA(&l, from: 0, to: 11000)
  XCTAssertEqual(l.evaluate(now: at(10_000)), .healthy)
  XCTAssertEqual(l.evaluate(now: at(10_001)), .rebuildVideo(.receiveSilent))
 }

 func testFaultRow7b_VideoConnectionErrorRebuildsVideoOnly() {
  var l = AttachmentLiveness(now: 0)
  heartbeatsOnA(&l, from: 0, to: 1000)
  l.connectionFailed(.video)
  XCTAssertEqual(l.evaluate(now: at(1000)), .rebuildVideo(.connectionFailed))
  XCTAssertFalse(l.evaluate(now: at(1000)).cancelsInput)
 }

 func testFaultRow7_ControlSilenceIsDeathEvenWhileVideoIsHealthy() {
  var l = AttachmentLiveness(now: 0)
  for t in stride(from: 0, through: 4000, by: 16) { l.received(on: .video, now: at(t)); l.videoSendQueue(queuedBytes: 0, drained: true, now: at(t)) }
  XCTAssertEqual(l.evaluate(now: at(3000)), .healthy)
  let health = l.evaluate(now: at(3001))
  XCTAssertEqual(health, .attachmentDead(.controlSilent)); XCTAssertTrue(health.cancelsInput)
 }

 func testFaultRow7_ControlErrorIsDeathAndOutranksVideoState() {
  var l = AttachmentLiveness(now: 0)
  l.connectionFailed(.video); l.connectionFailed(.controlInput)
  XCTAssertEqual(l.evaluate(now: 0), .attachmentDead(.controlFailed))
 }

 func testVideoActivityNeverKeepsControlAlive() {
  var l = AttachmentLiveness(now: 0)
  for t in stride(from: 0, through: 5000, by: 10) { l.received(on: .video, now: at(t)) }
  XCTAssertEqual(l.evaluate(now: at(5000)), .attachmentDead(.controlSilent))
 }

 func testOutOfOrderReportsNeverMoveTimeBackwards() {
  var l = AttachmentLiveness(now: 0)
  l.received(on: .controlInput, now: at(2000)); l.received(on: .controlInput, now: at(500))
  XCTAssertEqual(l.evaluate(now: at(4900)), .healthy)
  XCTAssertEqual(l.evaluate(now: at(5001)), .attachmentDead(.controlSilent))
 }
}
