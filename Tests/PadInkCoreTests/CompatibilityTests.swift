import XCTest
@testable import PadInkCore
final class CompatibilityTests: XCTestCase {
 func testLocalizedTitlesAndVersionWhitelistAreNotInputs() {
  let items = [ZoomMenuItem(token: 1, character: "+", modifiers: 0), ZoomMenuItem(token: 2, character: "-", modifiers: 0), ZoomMenuItem(token: 3, identifier: "actualSize:")]
  for family in [ApplicationFamily.preview, .safari, .chrome, .goodnotes] {
   XCTAssertEqual(ZoomMenuMatcher.match(.zoomIn, family: family, items: items), 1)
   XCTAssertEqual(ZoomMenuMatcher.match(.zoomOut, family: family, items: items), 2)
   XCTAssertEqual(ZoomMenuMatcher.match(.reset, family: family, items: items), 3)
  }
 }
 func testAmbiguousDisabledOrWrongModifierMenuIsUnavailable() {
  let first = ZoomMenuItem(token: 1, character: "+", modifiers: 0)
  XCTAssertNil(ZoomMenuMatcher.match(.zoomIn, family: .safari, items: [first, ZoomMenuItem(token: 2, character: "=", modifiers: 0)]))
  for modifier in [2, 4, 8] { XCTAssertNil(ZoomMenuMatcher.match(.zoomIn, family: .preview, items: [ZoomMenuItem(token: 1, character: "+", modifiers: modifier)])) }
  XCTAssertNil(ZoomMenuMatcher.match(.zoomIn, family: .chrome, items: [ZoomMenuItem(token: 1, identifier: "zoomIn:", enabled: false)]))
  XCTAssertNil(ZoomMenuMatcher.match(.zoomIn, family: .generic, items: [first]))
 }
 func testZoomDemandIsBoundedAndReversalDropsOldDirection() {
  var s = DiscreteZoom(); s.add(logDelta: 1)
  XCTAssertEqual(s.take(now: 0), .zoomIn); XCTAssertNil(s.take(now: 1))
  XCTAssertEqual(s.take(now: 180_000_000), .zoomIn); XCTAssertNil(s.take(now: 360_000_000))
  s.add(logDelta: 1); s.add(logDelta: -0.2)
  XCTAssertEqual(s.take(now: 400_000_000), .zoomOut); XCTAssertLessThan(abs(s.demand), s.threshold)
  s.add(logDelta: .nan); XCTAssertFalse(s.hasStep)
 }
 func testSmallPinchCorrectionsPreserveNetMovementUntilARealStep() {
  for direction in [1.0, -1.0] {
   var s = DiscreteZoom()
   for _ in 0..<14 { s.add(logDelta: direction * 0.01); s.add(logDelta: -direction * 0.001) }
   XCTAssertEqual(s.take(now: 0), direction > 0 ? .zoomIn : .zoomOut)
   XCTAssertFalse(s.hasStep)
  }
 }

 func testSmallCorrectionDoesNotDiscardAnAlreadyAccumulatedStep() {
  var s = DiscreteZoom(); s.add(logDelta: 1.5 * s.threshold)
  s.add(logDelta: -0.01)
  XCTAssertEqual(s.take(now: 0), .zoomIn)
  XCTAssertFalse(s.hasStep)
 }
 func testSustainedReversalDropsPendingOldDirectionBeforeItCanBeSubmitted() {
  var s = DiscreteZoom(); s.add(logDelta: 1)
  for _ in 0..<6 { s.add(logDelta: -0.01) }
  XCTAssertNil(s.take(now: 0))
  s.add(logDelta: -1.6 * s.threshold)
  XCTAssertEqual(s.take(now: 0), .zoomOut)
 }
 func testDelayUntilNextStepIsTheRemainderOfTheIntervalSinceTheLastTake() {
  var s = DiscreteZoom(); XCTAssertNil(s.delayUntilNextStep(now: 0), "no demand, no wait")
  s.add(logDelta: 1); XCTAssertEqual(s.delayUntilNextStep(now: 5), 0, "first step is never throttled")
  XCTAssertEqual(s.take(now: 1_000), .zoomIn)
  XCTAssertEqual(s.delayUntilNextStep(now: 1_000 + 50_000_000), 130_000_000)
  XCTAssertEqual(s.delayUntilNextStep(now: 1_000 + 179_999_999), 1)
  XCTAssertEqual(s.delayUntilNextStep(now: 1_000 + 180_000_000), 0)
  XCTAssertEqual(s.delayUntilNextStep(now: 1_000 + 250_000_000), 0)
  XCTAssertNil(s.take(now: 1_000 + 179_999_999)); XCTAssertEqual(s.take(now: 1_000 + 180_000_000), .zoomIn)
  XCTAssertNil(s.delayUntilNextStep(now: 1_000 + 180_000_000), "demand consumed")
 }


}
