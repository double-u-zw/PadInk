import XCTest
@testable import PadInkCore

final class TouchTests: XCTestCase {
 private func finger(_ id: UInt64 = 1, _ x: Double = 10, _ y: Double = 10) -> FingerPoint { FingerPoint(id, CGPoint(x: x, y: y)) }
 private func event(_ seq: UInt32, phase: TouchPhase, kind: TouchKind = .pointer) -> TouchEvent { TouchEvent(gestureID: (1 << 63) + 1, sequence: seq, timestamp: UInt64(seq), geometryGeneration: 1, kind: kind, phase: phase, x: 0.5, y: 0.5) }
 private var geometry: PresentedGeometry { PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 100, videoHeight: 100) }
 func testGoldenPayloadAndMalformedInputs() throws {
  let e = event(1, phase: .began), data = try e.encoded()
  XCTAssertEqual(data.map { String(format: "%02x", $0) }.joined(), "800000000000000100000001000000000000000100000001010101003f0000003f0000000000000000000000")
  XCTAssertEqual(try TouchEvent(data, type: .pointer), e)
  for n in 0..<44 { XCTAssertThrowsError(try TouchEvent(data.prefix(n), type: .pointer)) }
  XCTAssertThrowsError(try TouchEvent(data, type: .scroll))
  for index in [0, 24, 25, 26, 27] { var bad = data; bad[index] = 0; if index == 27 { bad[index] = 1 }; XCTAssertThrowsError(try TouchEvent(bad, type: .pointer)) }
  var bad = e; bad.x = .nan; XCTAssertThrowsError(try bad.encoded()); bad.x = 0; bad.dx = 1; XCTAssertThrowsError(try bad.encoded())
 }
 func testShortTapWaitsForPalmWindowAndDoubleTapHasClickCountTwo() {
  var f = GestureFSM(); f.touchEnabled = true
  XCTAssertTrue(f.update([finger()], now: 0).isEmpty)
  XCTAssertTrue(f.update([], now: 40_000_000).isEmpty)
  let first = f.timer(now: 80_000_000); XCTAssertEqual(first.map(\.phase), [.began, .ended]); XCTAssertEqual(first.map(\.clicks), [1, 1])
  _ = f.update([finger()], now: 100_000_000)
  let second = f.update([], now: 190_000_000); XCTAssertEqual(second.map(\.clicks), [2, 2])
 }
 func testVeryFastDoubleTapKeepsBothClicksAndStationaryCandidateHasNoBusyTimer() {
  var f = GestureFSM(); f.touchEnabled = true
  _ = f.update([finger()], now: 0); _ = f.update([], now: 10_000_000)
  _ = f.update([finger()], now: 20_000_000); _ = f.update([], now: 30_000_000)
  XCTAssertEqual(f.timer(now: 100_000_000).map(\.clicks), [1, 1, 2, 2])
  _ = f.update([finger()], now: 200_000_000); _ = f.timer(now: 280_000_000)
  XCTAssertNil(f.deadline)
 }
 func testRandomInterleavingsKeepEveryDownBalancedAndPencilPriority() {
  var f = GestureFSM(); f.touchEnabled = true; var seed: UInt64 = 123, down: UInt64?, pencil = false
  func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed }
  func check(_ actions: [TouchAction]) {
   for a in actions {
    if a.phase == .began { XCTAssertNil(down); XCTAssertFalse(pencil); down = a.id }
    else { XCTAssertEqual(down, a.id) }
    if a.phase == .ended || a.phase == .cancelled { down = nil }
   }
  }
  for t in 0..<3000 {
   let now = UInt64(t) * 10_000_000, n = next() % 8
   if n == 0 { pencil = true; check(f.setPencil(true, now: now)) }
   else if n == 1 { pencil = false; check(f.setPencil(false, now: now)) }
   else if n == 2 { check(f.timer(now: now)) }
   else { let count = Int(next() % 4); check(f.update((0..<count).map { finger(UInt64($0 + 1), Double(next() % 300), Double(next() % 300)) }, now: now)) }
  }
  check(f.cancel(now: 31_000_000_000)); XCTAssertNil(down)
 }
 func testPencilAndHoverCancelWithoutRevivingHeldFingers() {
  for hover in [false, true] {
   var f = GestureFSM(); f.touchEnabled = true
   _ = f.update([finger()], now: 0)
   XCTAssertEqual(f.update([finger(1, 30)], now: 100_000_000).map(\.phase), [.began, .changed])
   XCTAssertEqual(f.setPencil(true, hover: hover, now: 110_000_000).map(\.phase), [.cancelled])
   _ = f.setPencil(false, hover: hover, now: 120_000_000)
   XCTAssertTrue(f.update([finger(1, 80)], now: 140_000_000).isEmpty)
   _ = f.update([], now: 150_000_000); _ = f.update([finger()], now: 200_000_000)
   XCTAssertEqual(f.update([finger(1, 30)], now: 300_000_000).count, 2)
  }
 }
 func testRepeatedPencilAbsentDoesNotInterruptFingerDrag() {
  var f = GestureFSM(); f.touchEnabled = true; _ = f.update([finger()], now: 0)
  _ = f.update([finger(1, 30)], now: 100_000_000); _ = f.setPencil(false, now: 110_000_000)
  XCTAssertEqual(f.update([finger(1, 40)], now: 120_000_000).map(\.phase), [.changed])
 }
 func testPencilBeforeConfirmationPreventsAnyPointerDown() {
  var f = GestureFSM(); f.touchEnabled = true
  _ = f.update([finger()], now: 0); _ = f.update([], now: 20_000_000)
  XCTAssertTrue(f.setPencil(true, now: 30_000_000).isEmpty); XCTAssertTrue(f.timer(now: 100_000_000).isEmpty)
 }
 func testTwoFingerScrollAndPinchAreClassifiedOnlyOnce() {
  var f = GestureFSM(); f.touchEnabled = true
  _ = f.update([finger(1, 0), finger(2, 100)], now: 0)
  let scroll = f.update([finger(1, 0, 20), finger(2, 100, 20)], now: 100_000_000)
  XCTAssertEqual(scroll.map(\.kind), [.scroll, .scroll]); XCTAssertEqual(scroll.last?.delta.y, 10)
  XCTAssertTrue(f.update([finger(1, 10, 20), finger(2, 90, 20)], now: 110_000_000).allSatisfy { $0.kind == .scroll })
  _ = f.update([], now: 120_000_000)
  _ = f.update([finger(1, 0), finger(2, 100)], now: 200_000_000)
  let pinch = f.update([finger(1, -10), finger(2, 110)], now: 300_000_000)
  XCTAssertEqual(pinch.map(\.kind), [.magnify, .magnify]); XCTAssertGreaterThan(pinch.last!.delta.x, 0)
 }
 func testPinchKeepsOriginalCenterAndEmitsTranslationWithoutScale() {
  var f = GestureFSM(); f.touchEnabled = true
  _ = f.update([finger(1, 0), finger(2, 100)], now: 0)
  let began = f.update([finger(1, -8), finger(2, 112)], now: 100_000_000)
  XCTAssertEqual(began.first?.point.x, 50)
  XCTAssertEqual(began.last?.point.x, 52)
  let moved = f.update([finger(1, 2), finger(2, 122)], now: 120_000_000)
  XCTAssertEqual(moved.count, 1); XCTAssertEqual(moved.first?.kind, .magnify)
  XCTAssertEqual(moved.first?.delta.x, 0); XCTAssertEqual(moved.first?.point.x, 62)
  XCTAssertEqual(f.setPencil(true, now: 130_000_000).first?.phase, .cancelled)
  XCTAssertTrue(f.update([finger(1, 3), finger(2, 123)], now: 140_000_000).isEmpty)
 }
 func testOnlyPencilModeAndThirdFingerNeverGenerateClicks() {
  var f = GestureFSM(); _ = f.update([finger()], now: 0)
  XCTAssertTrue(f.update([], now: 100_000_000).isEmpty)
  f.touchEnabled = true; _ = f.update([finger(), finger(2), finger(3)], now: 200_000_000)
  XCTAssertTrue(f.update([finger()], now: 300_000_000).isEmpty); XCTAssertTrue(f.update([], now: 400_000_000).isEmpty)
 }
 func testOwnershipStaleTerminalReleasesAndNeverRevives() {
  var o = TouchOwnership(); o.enabled = true; _ = o.updateGeometry(geometry)
  XCTAssertEqual(o.receive(event(1, phase: .began), stamp: .init(localTime: 0), now: 1, pencilActive: false), [.inject(event(1, phase: .began))])
  let end = event(2, phase: .ended)
  let commands = o.receive(end, stamp: .init(localTime: 2), now: 200_000_000, pencilActive: false)
  XCTAssertTrue(commands.contains(.release(.staleSample))); XCTAssertNil(o.active)
  XCTAssertTrue(o.receive(event(3, phase: .changed), stamp: .init(localTime: 200_000_001), now: 200_000_001, pencilActive: false).isEmpty)
 }
 func testStationaryDeadlineKeepaliveGeometryAndPencilPreemption() {
  var o = TouchOwnership(); o.enabled = true; _ = o.updateGeometry(geometry)
  let e = event(1, phase: .began); _ = o.receive(e, stamp: .init(localTime: 0), now: 1, pencilActive: false)
  XCTAssertTrue(o.timer(now: o.deadline!).contains(.release(.gestureTimeout)))
  XCTAssertTrue(o.keepalive(.init(gestureID: e.gestureID, lastSampleSequence: 1), stamp: .init(localTime: 1_100_000_000), now: 1_100_000_000).isEmpty)
  var n = TouchOwnership(); n.enabled = true; _ = n.updateGeometry(geometry)
  XCTAssertFalse(n.receive(e, stamp: .init(localTime: 0), now: 1, pencilActive: true).contains(.inject(e)))
  n = TouchOwnership(); n.enabled = true; _ = n.updateGeometry(geometry); _ = n.receive(e, stamp: .init(localTime: 0), now: 1, pencilActive: false)
  var changed = geometry; changed.generation = 2
  XCTAssertTrue(n.updateGeometry(changed).contains(.release(.geometryMismatch)))
 }
}
