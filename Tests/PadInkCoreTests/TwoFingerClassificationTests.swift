import XCTest
@testable import PadInkCore

final class TwoFingerClassificationTests: XCTestCase {
 private func points(_ a: Double, _ b: Double) -> [FingerPoint] { [FingerPoint(1, CGPoint(x: a, y: 100)), FingerPoint(2, CGPoint(x: b, y: 100))] }
 private func started(_ a: Double = 100, _ b: Double = 160) -> GestureFSM {
  var f = GestureFSM(); f.touchEnabled = true; _ = f.update(points(a, b), now: 0); return f
 }
 func testStaggeredParallelMovementDoesNotLockScrollAsPinch() {
  var f = started()
  XCTAssertTrue(f.update(points(104, 160), now: 100_000_000).isEmpty)
  let result = f.update(points(104, 164), now: 108_000_000)
  XCTAssertEqual(result.map(\.kind), [.scroll, .scroll]); XCTAssertEqual(result.last?.delta.x, 4)
 }
 func testStaggeredPinchDoesNotLockAsScrollBeforeSecondFingerMoves() {
  var f = started(100, 300)
  XCTAssertTrue(f.update(points(93, 300), now: 100_000_000).isEmpty)
  XCTAssertEqual(f.update(points(93, 307), now: 108_000_000).map(\.kind), [.magnify, .magnify])
 }
 func testUnequalParallelMovementUsesDominantTranslation() {
  var f = started(100, 150)
  let result = f.update(points(110, 170), now: 100_000_000)
  XCTAssertEqual(result.map(\.kind), [.scroll, .scroll]); XCTAssertEqual(result.last?.delta.x, 15)
 }
 func testAnchoredPinchGetsOneSettlingTimerAndStillWorks() {
  var f = started()
  XCTAssertTrue(f.update(points(90, 160), now: 100_000_000).isEmpty)
  XCTAssertEqual(f.deadline, 120_000_000)
  XCTAssertTrue(f.timer(now: 119_999_999).isEmpty)
  XCTAssertEqual(f.timer(now: 120_000_000).map(\.kind), [.magnify, .magnify])
  XCTAssertNil(f.deadline)
 }
 func testEarlyMovementIsClassifiedAtTwoFingerConfirmationWithoutAnotherMove() {
  var f = started()
  XCTAssertEqual(f.deadline, 80_000_000)
  XCTAssertTrue(f.update(points(105, 165), now: 40_000_000).isEmpty)
  XCTAssertEqual(f.timer(now: 80_000_000).map(\.kind), [.scroll, .scroll]); XCTAssertNil(f.deadline)
 }
 func testSecondFingerHasItsOwnPalmConfirmationWindow() {
  var f = GestureFSM(); f.touchEnabled = true
  _ = f.update([FingerPoint(1, CGPoint(x: 100, y: 100))], now: 0)
  _ = f.update(points(100, 160), now: 75_000_000)
  XCTAssertTrue(f.update(points(105, 165), now: 90_000_000).isEmpty)
  XCTAssertEqual(f.deadline, 155_000_000)
  XCTAssertEqual(f.timer(now: 155_000_000).map(\.kind), [.scroll, .scroll])
 }
 func testPencilCancelsSettlingCandidateWithoutLateTouchBegin() {
  var f = started(); _ = f.update(points(90, 160), now: 100_000_000)
  XCTAssertTrue(f.setPencil(true, now: 110_000_000).isEmpty)
  XCTAssertNil(f.deadline); XCTAssertTrue(f.timer(now: 120_000_000).isEmpty)
 }
}
