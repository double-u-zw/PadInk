import XCTest
@testable import PadInkCore

/// Fault rows 2 and 6 (docs/ARCHITECTURE.md §5). Clock in milliseconds, local only.
final class InputFreshnessTests: XCTestCase {
 private let policy = InputFreshnessPolicy.initial // 100 ms queue age, 1 s gesture timeout
 private func t(_ ms: Int) -> UInt64 { UInt64(ms) * 1_000_000 }
 private func stamp(_ ms: Int) -> ReceiveStamp { ReceiveStamp(localTime: t(ms)) }
 private func gesture() -> GestureFreshness { GestureFreshness(gestureID: 1, began: stamp(0)) }

 func testFreshSampleInjectsAndBoundariesAreInclusive() {
  var g = gesture()
  XCTAssertEqual(g.verdict(for: stamp(0), now: t(5), policy: policy), .inject)
  XCTAssertEqual(g.verdict(for: stamp(10), now: t(110), policy: policy), .inject)
  XCTAssertFalse(g.expireIfDue(now: t(1000) - 1, policy: policy))
  XCTAssertTrue(g.expireIfDue(now: t(1000), policy: policy))
 }

 /// Review P2: a single one-shot timer firing exactly at deadline() must release a stationary
 /// gesture, and report it once.
 func testOneShotTimerAtPublishedDeadlineReleasesExactlyOnce() {
  for activity in [0, 370, 999] {
   var g = gesture()
   if activity > 0 { XCTAssertEqual(g.keepaliveReceived(stamp(activity), now: t(activity), policy: policy), .refreshed) }
   let fire = g.deadline(policy: policy)
   XCTAssertTrue(g.alive(now: fire - 1, policy: policy)); XCTAssertFalse(g.alive(now: fire, policy: policy))
   XCTAssertTrue(g.expireIfDue(now: fire, policy: policy), "timer at deadline after activity \(activity)")
   XCTAssertFalse(g.expireIfDue(now: fire, policy: policy))
   XCTAssertEqual(g.endReason, .timeout)
  }
 }

 func testMessageArrivingExactlyAtDeadlineIsLate() {
  var g = gesture()
  XCTAssertEqual(g.keepaliveReceived(stamp(1000), now: t(1000), policy: policy), .expired)
 }

 // MARK: Review round 2 — a late message must not revive a timed-out gesture

 /// Reviewer's sequence: 0 start; 1001 timed out (no timer has run); 1100 late keepalive; 1101 verdict.
 func testReviewerSequenceLateKeepaliveCannotRevive() {
  var g = gesture()
  XCTAssertFalse(g.alive(now: t(1000), policy: policy))
  XCTAssertEqual(g.keepaliveReceived(stamp(1100), now: t(1100), policy: policy), .expired)
  XCTAssertEqual(g.endReason, .timeout)
  XCTAssertEqual(g.verdict(for: stamp(1100), now: t(1101), policy: policy), .gestureEnded)
 }

 func testReviewerSequenceLateSampleCannotRevive() {
  var g = gesture()
  XCTAssertEqual(g.sampleReceived(stamp(1100), now: t(1100), policy: policy), .expired)
  XCTAssertEqual(g.verdict(for: stamp(1100), now: t(1101), policy: policy), .gestureEnded)
 }

 /// A message that arrived (stamp 999) before the deadline but is processed after it (1100):
 /// the timer callback and the message reach the same state in either order.
 func testTimerAndLateMessageOrderDoesNotChangeOutcome() {
  for keepalive in [true, false] {
   var timerFirst = gesture(), messageFirst = gesture()
   XCTAssertTrue(timerFirst.expireIfDue(now: t(1100), policy: policy))
   let late = keepalive ? timerFirst.keepaliveReceived(stamp(999), now: t(1100), policy: policy) : timerFirst.sampleReceived(stamp(999), now: t(1100), policy: policy)
   XCTAssertEqual(late, .ignored)

   let first = keepalive ? messageFirst.keepaliveReceived(stamp(999), now: t(1100), policy: policy) : messageFirst.sampleReceived(stamp(999), now: t(1100), policy: policy)
   XCTAssertEqual(first, .expired)
   XCTAssertFalse(messageFirst.expireIfDue(now: t(1100), policy: policy))

   XCTAssertEqual(timerFirst, messageFirst)
   XCTAssertEqual(timerFirst.endReason, .timeout)
  }
 }

 /// Before the deadline the same late-processed message is a legitimate refresh.
 func testMessageProcessedBeforeDeadlineRefreshes() {
  var g = gesture()
  XCTAssertEqual(g.keepaliveReceived(stamp(990), now: t(999), policy: policy), .refreshed)
  XCTAssertEqual(g.deadline(policy: policy), t(1990))
  XCTAssertFalse(g.expireIfDue(now: t(1990) - 1, policy: policy))
  XCTAssertTrue(g.expireIfDue(now: t(1990), policy: policy))
 }

 func testPreInjectionVerdictAlsoLocksTimeout() {
  var g = gesture()
  XCTAssertEqual(g.verdict(for: stamp(1050), now: t(1060), policy: policy), .gestureExpired)
  XCTAssertEqual(g.keepaliveReceived(stamp(1070), now: t(1070), policy: policy), .ignored)
  XCTAssertEqual(g.verdict(for: stamp(1070), now: t(1071), policy: policy), .gestureEnded)
 }

 /// Stationary pencil with no further messages: only the timer check can release it.
 func testFaultRow6_TimerReleasesStationaryGestureExactlyOnce() {
  var g = gesture()
  XCTAssertEqual(g.deadline(policy: policy), t(1000))
  XCTAssertFalse(g.expireIfDue(now: t(999), policy: policy))
  XCTAssertTrue(g.expireIfDue(now: t(1000), policy: policy))
  XCTAssertFalse(g.expireIfDue(now: t(5000), policy: policy))
  XCTAssertEqual(g.sampleReceived(stamp(5001), now: t(5001), policy: policy), .ignored)
 }

 func testProcessingClockNeverMovesBackwards() {
  var g = gesture()
  XCTAssertTrue(g.expireIfDue(now: t(1200), policy: policy))
  XCTAssertEqual(g.keepaliveReceived(stamp(500), now: t(500), policy: policy), .ignored)
  XCTAssertEqual(g.verdict(for: stamp(500), now: t(501), policy: policy), .gestureEnded)
  // Without a prior call, an earlier `now` after a later one still cannot reopen the deadline.
  var h = gesture()
  XCTAssertEqual(h.verdict(for: stamp(1001), now: t(1001), policy: policy), .gestureExpired)
  XCTAssertFalse(h.expireIfDue(now: t(10), policy: policy))
  XCTAssertTrue(h.ended)
 }

 // MARK: Rows 2 and 6 behaviour kept from round 1

 /// The input queue backs up while keepalives keep arriving: the gesture stays alive but the
 /// queued sample still goes stale.
 func testFaultRow2_KeepaliveDoesNotRefreshQueuedSampleAge() {
  var g = gesture()
  let queued = stamp(0)
  for ms in stride(from: 50, through: 400, by: 50) { XCTAssertEqual(g.keepaliveReceived(stamp(ms), now: t(ms), policy: policy), .refreshed) }
  XCTAssertTrue(g.alive(now: t(400), policy: policy))
  XCTAssertEqual(g.verdict(for: queued, now: t(400), policy: policy), .stale(age: t(400)))
  XCTAssertEqual(g.endReason, .staleSample)
 }

 func testFaultRow2_StaleSampleEndsGestureAndLaterMessagesAreIgnored() {
  var g = gesture()
  XCTAssertEqual(g.verdict(for: stamp(0), now: t(150), policy: policy), .stale(age: t(150)))
  XCTAssertEqual(g.sampleReceived(stamp(160), now: t(160), policy: policy), .ignored)
  XCTAssertEqual(g.keepaliveReceived(stamp(170), now: t(170), policy: policy), .ignored)
  XCTAssertEqual(g.verdict(for: stamp(160), now: t(171), policy: policy), .gestureEnded)
  XCTAssertFalse(g.expireIfDue(now: t(5000), policy: policy))
  XCTAssertEqual(g.endReason, .staleSample)
 }

 func testFaultRow6_StationaryHoldStaysAliveOnKeepalivesOnly() {
  var g = gesture()
  for ms in stride(from: 200, through: 3000, by: 200) {
   XCTAssertFalse(g.expireIfDue(now: t(ms), policy: policy))
   XCTAssertEqual(g.keepaliveReceived(stamp(ms), now: t(ms), policy: policy), .refreshed)
  }
  XCTAssertEqual(g.verdict(for: stamp(2995), now: t(3000), policy: policy), .inject)
 }

 func testCancelledGestureRejectsEverythingAndKeepsReason() {
  var g = gesture(); g.cancel()
  XCTAssertEqual(g.verdict(for: stamp(1), now: t(1), policy: policy), .gestureEnded)
  XCTAssertFalse(g.expireIfDue(now: t(5000), policy: policy))
  XCTAssertEqual(g.endReason, .cancelled)
 }

 /// Random interleavings of samples, keepalives, timer checks and verdicts with arbitrary
 /// processing delays. Invariants: never inject past the deadline or past maxQueueAge; once
 /// ended, never inject again; the end is reported at most once.
 func testRandomInterleavingsKeepTimeoutIrreversible() {
  var rng = SystemRandomNumberGenerator()
  for _ in 0..<3_000 {
   var g = gesture(), now = 0, lastStamp = 0, endReports = 0, everEnded = false
   for _ in 0..<40 {
    now += Int.random(in: 0...450, using: &rng)
    let stampMs = max(lastStamp, now - Int.random(in: 0...200, using: &rng)); lastStamp = stampMs
    let deadlineBefore = g.deadline(policy: policy), endedBefore = g.ended
    switch Int.random(in: 0...3, using: &rng) {
    case 0: if g.sampleReceived(stamp(stampMs), now: t(now), policy: policy) == .expired { endReports += 1 }
    case 1: if g.keepaliveReceived(stamp(stampMs), now: t(now), policy: policy) == .expired { endReports += 1 }
    case 2: if g.expireIfDue(now: t(now), policy: policy) { endReports += 1 }
    default:
     let v = g.verdict(for: stamp(stampMs), now: t(now), policy: policy)
     switch v {
     case .inject:
      XCTAssertFalse(everEnded); XCTAssertLessThan(t(now), deadlineBefore)
      XCTAssertLessThanOrEqual(t(now) - t(stampMs), policy.maxQueueAge)
     case .gestureExpired, .stale: endReports += 1
     case .gestureEnded: XCTAssertTrue(endedBefore)
     }
    }
    if !endedBefore && t(now) >= deadlineBefore { XCTAssertTrue(g.ended, "deadline passed at processing time but gesture still open") }
    everEnded = everEnded || g.ended
    XCTAssertLessThanOrEqual(endReports, 1)
   }
  }
 }
}
