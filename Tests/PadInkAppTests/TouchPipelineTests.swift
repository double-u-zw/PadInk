import XCTest
import AppKit
import PadInkCore
@testable import PadInkMacKit
final class TouchPipelineTests: XCTestCase {
 private func event(_ seq: UInt32, _ phase: TouchPhase, _ kind: TouchKind = .pointer) -> TouchEvent { TouchEvent(gestureID: (1 << 63) + 1, sequence: seq, timestamp: UInt64(seq), geometryGeneration: 1, kind: kind, phase: phase, x: 0.5, y: 0.5) }
 private func pipeline(_ post: @escaping (CGEvent) -> Void) -> TouchInputPipeline {
  let b = PointerInjectionBackend(postEvent: post); b.displayBounds = CGRect(x: -100, y: 0, width: 1000, height: 500)
  let p = TouchInputPipeline(backend: b, diagnostics: Diagnostics()); p.attach(); p.setEnabled(true)
  p.geometry(PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 1000, videoHeight: 500)); return p
 }
 func testPointerUsesCanonicalMappingAndSafeUpIsIdempotent() {
  var events: [CGEvent] = []; let p = pipeline { events.append($0) }
  p.receive(event(1, .began), stamp: .init(localTime: 0), now: 0, pencilActive: false)
  XCTAssertEqual(events.first?.location, CGPoint(x: 400, y: 250)); XCTAssertEqual(events.first?.type, .leftMouseDown)
  p.cancel(.pencilPreempted); p.cancel(.pencilPreempted)
  XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp]); XCTAssertFalse(p.backend.pressed)
  p.receive(event(2, .changed), stamp: .init(localTime: 1), now: 1, pencilActive: false)
  XCTAssertEqual(events.count, 2)
 }
 func testStaleTerminalAndDeadlineBothReleaseRealBackend() {
  for timeout in [false, true] {
   var events: [CGEvent] = []; let p = pipeline { events.append($0) }
   p.receive(event(1, .began), stamp: .init(localTime: 0), now: 0, pencilActive: false)
   if timeout { p.timer(now: 1_000_000_000) } else { p.receive(event(2, .ended), stamp: .init(localTime: 1), now: 200_000_000, pencilActive: false) }
   XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp]); XCTAssertNil(p.ownership.active)
  }
 }
 func testScrollDirectionAndPhasesUsePublicEvents() {
  var events: [CGEvent] = []; let p = pipeline { events.append($0) }
  p.receive(event(1, .began, .scroll), stamp: .init(localTime: 0), now: 0, pencilActive: false)
  var moved = event(2, .changed, .scroll); moved.dy = 0.1
  p.receive(moved, stamp: .init(localTime: 1), now: 1, pencilActive: false)
  XCTAssertEqual(events.last?.type, .scrollWheel)
  XCTAssertLessThan(events.last!.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), 0)
  p.cancel(.targetChanged); XCTAssertEqual(events.last!.getIntegerValueField(.scrollWheelEventScrollPhase), 8)
 }
 func testSlowScrollPreservesSubpixelMotionThroughAppKit() {
  var events: [CGEvent] = []; let p = pipeline { events.append($0) }
  p.receive(event(1, .began, .scroll), stamp: .init(localTime: 0), now: 0, pencilActive: false)
  for seq in 2...101 {
   var moved = event(UInt32(seq), .changed, .scroll); moved.dy = 0.0006 // 0.3 Mac pixels per frame
   p.receive(moved, stamp: .init(localTime: UInt64(seq)), now: UInt64(seq), pencilActive: false)
  }
  p.receive(event(102, .ended, .scroll), stamp: .init(localTime: 102), now: 102, pencilActive: false)
  let displacement = events.compactMap { NSEvent(cgEvent: $0)?.scrollingDeltaY }.reduce(0, +)
  XCTAssertEqual(displacement, -30, accuracy: 1)
 }
 func testScrollTerminalFlushesRemainderAndCancellationDoesNotLeakToNextGesture() throws {
  for phase in [TouchPhase.ended, .cancelled] {
   var posted: [CGEvent] = []; let b = PointerInjectionBackend { posted.append($0) }
   b.displayBounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
   try b.deliver(event(1, .began, .scroll))
   var move = event(2, .changed, .scroll); move.dx = 0.0004; move.dy = -0.0008
   try b.deliver(move); move.sequence = 3; try b.deliver(move)
   try b.deliver(event(4, phase, .scroll))
   let totalX = posted.compactMap { NSEvent(cgEvent: $0)?.scrollingDeltaX }.reduce(0, +)
   let totalY = posted.compactMap { NSEvent(cgEvent: $0)?.scrollingDeltaY }.reduce(0, +)
   XCTAssertEqual(totalX, phase == .ended ? -1 : 0)
   XCTAssertEqual(totalY, phase == .ended ? 1 : 0)
   posted.removeAll(); try b.deliver(event(1, .began, .scroll)); try b.deliver(move)
   try b.deliver(event(4, .ended, .scroll))
   XCTAssertEqual(posted.compactMap { NSEvent(cgEvent: $0)?.scrollingDeltaY }.reduce(0, +), 0)
  }
 }
 func testOnlyPencilAndPencilActiveNeverPostPointerEvents() {
  var events: [CGEvent] = []; let p = pipeline { events.append($0) }
  p.receive(event(1, .began), stamp: .init(localTime: 0), now: 0, pencilActive: true)
  p.attach(); p.setEnabled(false); p.receive(event(1, .began), stamp: .init(localTime: 0), now: 0, pencilActive: false)
  XCTAssertTrue(events.isEmpty)
 }
 func testMagnifyStaysSemanticWithoutUndocumentedCGEvent() {
  var events: [CGEvent] = [], semantic: [TouchEvent] = []; let p = pipeline { events.append($0) }; p.backend.magnify = { semantic.append($0) }
  p.receive(event(1, .began, .magnify), stamp: .init(localTime: 0), now: 0, pencilActive: false)
  p.receive(event(2, .changed, .magnify), stamp: .init(localTime: 1), now: 1, pencilActive: false)
  XCTAssertTrue(events.isEmpty); XCTAssertEqual(semantic.count, 2)
 }
 func testScrollStaysAnchoredToOriginalTargetWhenFingerCrossesToolbarArea() {
  var events: [CGEvent] = []; let p = pipeline { events.append($0) }
  var start = event(1, .began, .scroll); start.y = 0.75
  p.receive(start, stamp: .init(localTime: 0), now: 0, pencilActive: false)
  var moved = event(2, .changed, .scroll); moved.y = 0.02; moved.dy = -0.4
  p.receive(moved, stamp: .init(localTime: 1), now: 1, pencilActive: false)
  var end = event(3, .ended, .scroll); end.y = 0.02
  p.receive(end, stamp: .init(localTime: 2), now: 2, pencilActive: false)
  XCTAssertEqual(events.map(\.location), Array(repeating: CGPoint(x: 400, y: 375), count: 3))
  XCTAssertGreaterThan(events[1].getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
 }

}
