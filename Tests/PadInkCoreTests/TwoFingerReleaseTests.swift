import XCTest
@testable import PadInkCore

final class TwoFingerReleaseTests: XCTestCase {
 private func pair(_ y: CGFloat = 100, pinch: Bool = false) -> [FingerPoint] {
  [FingerPoint(1, CGPoint(x: pinch ? 80 : 100, y: y)), FingerPoint(2, CGPoint(x: pinch ? 220 : 200, y: y))]
 }
 private func started(pinch: Bool) -> GestureFSM {
  var f = GestureFSM(); f.touchEnabled = true
  _ = f.update(pair(), now: 0)
  let actions = f.update(pair(pinch ? 100 : 130, pinch: pinch), now: 100_000_000)
  XCTAssertEqual(actions.first?.kind, pinch ? .magnify : .scroll)
  return f
 }
 func testScrollFirstFingerLiftEndsOnceWithoutStartingHeldFingerDrag() {
  for survivor in [0, 1] {
   var f = started(pinch: false), remaining = pair(130)[survivor]
   let end = f.update([remaining], now: 110_000_000)
   XCTAssertEqual(end.map(\.phase), [.ended]); XCTAssertEqual(end.first?.kind, .scroll); XCTAssertNil(f.active)
   remaining = FingerPoint(remaining.id, CGPoint(x: remaining.point.x, y: 220))
   XCTAssertTrue(f.update([remaining], now: 200_000_000).isEmpty)
   XCTAssertTrue(f.update([], now: 210_000_000).isEmpty)
   _ = f.update(pair(), now: 300_000_000)
   XCTAssertEqual(f.update(pair(140), now: 400_000_000).map(\.phase), [.began, .changed])
  }
 }
 func testPinchFirstFingerLiftEndsOnceWithoutDiscardingTerminalDemand() {
  for survivor in [0, 1] {
   var f = started(pinch: true)
   let end = f.update([pair(pinch: true)[survivor]], now: 110_000_000)
   XCTAssertEqual(end.map(\.phase), [.ended]); XCTAssertEqual(end.first?.kind, .magnify); XCTAssertNil(f.active)
   XCTAssertTrue(f.update([], now: 120_000_000).isEmpty)
  }
 }
 func testContactReplacementAndThirdFingerStillCancel() {
  for third in [false, true] {
   var f = started(pinch: false)
   let contacts = third ? pair(130) + [FingerPoint(3, CGPoint(x: 300, y: 130))] : [FingerPoint(3, CGPoint(x: 100, y: 130))]
   XCTAssertEqual(f.update(contacts, now: 110_000_000).map(\.phase), [.cancelled])
   XCTAssertNil(f.active)
  }
 }
 func testExplicitSystemCancellationNeverBecomesNormalEnd() {
  for pinch in [false, true] {
   var f = started(pinch: pinch)
   XCTAssertEqual(f.cancel(now: 110_000_000).map(\.phase), [.cancelled])
   XCTAssertTrue(f.update([pair()[0]], now: 120_000_000).isEmpty)
   XCTAssertTrue(f.update([], now: 130_000_000).isEmpty); XCTAssertNil(f.active)
  }
 }
 func testScrollBeginUsesOriginalTargetAfterConfirmationTravel() {
  var f = GestureFSM(); f.touchEnabled = true
  _ = f.update(pair(200), now: 0)
  let actions = f.update(pair(70), now: 100_000_000)
  XCTAssertEqual(actions.first?.kind, .scroll)
  XCTAssertEqual(actions.first?.point, CGPoint(x: 150, y: 200))
  XCTAssertEqual(actions.last?.delta.y, -130)
 }

}
