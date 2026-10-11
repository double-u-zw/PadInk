import XCTest
@testable import PadInkCore

/// Mac Pencil gatekeeping. Fault rows refer to docs/ARCHITECTURE.md §5. Clock in ms.
final class InputOwnershipTests: XCTestCase {
 private func t(_ ms: Int) -> UInt64 { UInt64(ms) * 1_000_000 }
 private func stamp(_ ms: Int) -> ReceiveStamp { ReceiveStamp(localTime: t(ms)) }
 private let presented = PresentedGeometry(generation: 3, ready: true, orientation: 4, videoWidth: 2360, videoHeight: 1534)

 private func batch(_ id: UInt64 = 1, gen: UInt32 = 3, from seq: UInt64 = 1, count: Int = 2, begin: Bool = true, end: Bool = false) -> PencilBatch {
  let samples = (0..<count).map { i -> PencilSample in
   let s = seq + UInt64(i)
   let phase: PencilPhase = (begin && i == 0) ? .begin : (end && i == count - 1) ? .end : .move
   return PencilSample(stroke: id, sequence: s, timestamp: s, x: 0.5, y: 0.5, pressure: 0.5, altitude: 1, azimuth: 0, phase: phase, geometryGeneration: gen)
  }
  return try! PencilBatch(samples)
 }
 private func ownership() -> InputOwnership { var o = InputOwnership(); _ = o.presentedGeometry(presented); return o }

 func testNormalStrokeInjectsEveryBatchAndEndsClean() {
  var o = ownership()
  let b1 = batch(), b2 = batch(from: 3, begin: false), b3 = batch(from: 5, count: 1, begin: false, end: true)
  XCTAssertEqual(o.pencil(b1, stamp: stamp(0), now: t(1)), [.inject(b1)])
  XCTAssertEqual(o.pencil(b2, stamp: stamp(10), now: t(11)), [.inject(b2)])
  XCTAssertEqual(o.pencil(b3, stamp: stamp(20), now: t(21)), [.inject(b3)])
  XCTAssertNotNil(o.active, "a terminal completes only once the backend has posted it")
  o.injected(b3)
  XCTAssertNil(o.active); XCTAssertNil(o.nextDeadline)
  XCTAssertEqual(o.pencil(b3, stamp: stamp(30), now: t(31)), [], "duplicate terminal is dropped silently")
 }

 /// Fault row 4: wrong or not-ready geometry rejects the stroke; the session is untouched.
 func testFaultRow4_GeometryMismatchRejectsStrokeOnly() {
  var o = ownership()
  XCTAssertEqual(o.pencil(batch(gen: 2), stamp: stamp(0), now: t(0)), [.reject(GestureNotice(gestureID: 1, reason: .geometryMismatch))])
  XCTAssertEqual(o.pencil(batch(gen: 2, from: 3, begin: false), stamp: stamp(5), now: t(5)), [], "later batches of the rejected stroke are dropped")
  _ = o.presentedGeometry(PresentedGeometry(generation: 4, ready: false, orientation: 4, videoWidth: 1, videoHeight: 1))
  XCTAssertEqual(o.pencil(batch(2, gen: 4), stamp: stamp(10), now: t(10)), [.reject(GestureNotice(gestureID: 2, reason: .geometryMismatch))])
  _ = o.presentedGeometry(PresentedGeometry(generation: 4, ready: true, orientation: 4, videoWidth: 1, videoHeight: 1))
  XCTAssertEqual(o.pencil(batch(3, gen: 4), stamp: stamp(20), now: t(20)).count, 1)
 }

 func testFaultRow4_GeometryChangeDuringStrokeReleases() {
  var o = ownership(); _ = o.pencil(batch(), stamp: stamp(0), now: t(0))
  XCTAssertEqual(o.presentedGeometry(PresentedGeometry(generation: 4, ready: false, orientation: 3, videoWidth: 1, videoHeight: 1)),
                 [.release(.geometryMismatch), .reject(GestureNotice(gestureID: 1, reason: .geometryMismatch))])
 }

 /// Fault row 2: a batch that waited past maxQueueAge before injection is dropped and the stroke ends.
 func testFaultRow2_StaleBatchReleasesAndRejects() {
  var o = ownership(); _ = o.pencil(batch(), stamp: stamp(0), now: t(1))
  let late = batch(from: 3, begin: false)
  XCTAssertEqual(o.pencil(late, stamp: stamp(10), now: t(150)), [.release(.staleSample), .reject(GestureNotice(gestureID: 1, reason: .staleSample))])
  XCTAssertEqual(o.pencil(batch(from: 5, begin: false), stamp: stamp(160), now: t(160)), [])
 }

 /// Fault row 6: stationary pencil held by keepalives, then released by the one-shot timer.
 func testFaultRow6_KeepalivesHoldAndTimerReleasesExactlyOnce() {
  var o = ownership(); _ = o.pencil(batch(), stamp: stamp(0), now: t(0))
  for ms in stride(from: 200, through: 2000, by: 200) { XCTAssertEqual(o.keepalive(GestureKeepalive(gestureID: 1, lastSampleSequence: 2), stamp: stamp(ms), now: t(ms)), []) }
  XCTAssertEqual(o.timer(now: t(2999)), [])
  let deadline = o.nextDeadline!
  XCTAssertEqual(deadline, t(3000))
  XCTAssertEqual(o.timer(now: deadline), [.release(.gestureTimeout), .reject(GestureNotice(gestureID: 1, reason: .gestureTimeout))])
  XCTAssertEqual(o.timer(now: deadline + 1), [])
  XCTAssertEqual(o.keepalive(GestureKeepalive(gestureID: 1, lastSampleSequence: 2), stamp: stamp(3100), now: t(3100)), [])
  XCTAssertEqual(o.pencil(batch(from: 3, begin: false), stamp: stamp(3100), now: t(3100)), [])
  XCTAssertEqual(o.cancelCounts[.gestureTimeout], 1)
 }

 func testLateBatchAfterDeadlineButBeforeTimerIsReleasedNotInjected() {
  var o = ownership(); _ = o.pencil(batch(), stamp: stamp(0), now: t(0))
  XCTAssertEqual(o.pencil(batch(from: 3, begin: false), stamp: stamp(1100), now: t(1100)), [.release(.gestureTimeout), .reject(GestureNotice(gestureID: 1, reason: .gestureTimeout))])
 }

 /// Fault rows 5 and 7.
 func testCancelAllReleasesAndOnlyRepliesWhenTransportIsUp() {
  var o = ownership(); _ = o.pencil(batch(), stamp: stamp(0), now: t(0))
  XCTAssertEqual(o.cancelAll(.targetChanged), [.release(.targetChanged), .reject(GestureNotice(gestureID: 1, reason: .targetChanged))])
  var p = ownership(); _ = p.pencil(batch(), stamp: stamp(0), now: t(0))
  XCTAssertEqual(p.cancelAll(.transportLost), [.release(.transportLost)])
  XCTAssertNil(p.geometry, "a new attachment must present geometry again before any stroke")
  XCTAssertEqual(p.pencil(batch(2), stamp: stamp(10), now: t(10)), [.reject(GestureNotice(gestureID: 2, reason: .geometryMismatch))])
  var idle = ownership(); XCTAssertEqual(idle.cancelAll(.targetChanged), [], "nothing owned, nothing released")
 }

 func testPeerCancelReleasesWithoutReply() {
  var o = ownership(); _ = o.pencil(batch(), stamp: stamp(0), now: t(0))
  XCTAssertEqual(o.cancelFromPeer(GestureNotice(gestureID: 1, reason: .geometryMismatch)), [.release(.geometryMismatch)])
  XCTAssertEqual(o.cancelFromPeer(GestureNotice(gestureID: 1, reason: .geometryMismatch)), [])
 }

 func testNewBeginWhileActiveEndsOldStrokeFirst() {
  var o = ownership(); _ = o.pencil(batch(1), stamp: stamp(0), now: t(0))
  let b = batch(2)
  XCTAssertEqual(o.pencil(b, stamp: stamp(5), now: t(5)), [.release(.protocolViolation), .reject(GestureNotice(gestureID: 1, reason: .protocolViolation)), .inject(b)])
 }

 func testContinuationOfUnknownStrokeIsRejectedOnce() {
  var o = ownership()
  XCTAssertEqual(o.pencil(batch(9, from: 40, begin: false), stamp: stamp(0), now: t(0)), [.reject(GestureNotice(gestureID: 9, reason: .sessionReplaced))])
  XCTAssertEqual(o.pencil(batch(9, from: 42, begin: false), stamp: stamp(1), now: t(1)), [])
 }

 /// Review of 71bdd94, P1 #1: a terminal batch the backend rejects must still be released.
 func testRejectedTerminalBatchIsStillReleased() {
  var o = ownership(); _ = o.pencil(batch(), stamp: stamp(0), now: t(0))
  let gapEnd = batch(from: 5, count: 1, begin: false, end: true)
  XCTAssertEqual(o.pencil(gapEnd, stamp: stamp(5), now: t(5)), [.inject(gapEnd)])
  XCTAssertEqual(o.backendRejected(gestureID: 1), [.release(.protocolViolation), .reject(GestureNotice(gestureID: 1, reason: .protocolViolation))])
  XCTAssertNil(o.active)
 }

 /// Review of 71bdd94, P1 #3: gesture IDs restart at 1 after an iPad relaunch; the ended record is per session.
 func testEndedRecordDoesNotOutliveTheAttachment() {
  var o = ownership()
  let b = batch(count: 1, begin: true); let e = batch(from: 2, count: 1, begin: false, end: true)
  _ = o.pencil(b, stamp: stamp(0), now: t(0)); o.injected(b); _ = o.pencil(e, stamp: stamp(1), now: t(1)); o.injected(e)
  _ = o.cancelAll(.transportLost); _ = o.presentedGeometry(presented)
  XCTAssertEqual(o.pencil(b, stamp: stamp(10), now: t(10)), [.inject(b)], "gesture 1 of the new session must be written")
 }

 func testBackendRejectionReleasesAndRejects() {
  var o = ownership(); _ = o.pencil(batch(), stamp: stamp(0), now: t(0))
  XCTAssertEqual(o.backendRejected(gestureID: 1), [.release(.protocolViolation), .reject(GestureNotice(gestureID: 1, reason: .protocolViolation))])
 }
}
