#if os(macOS)
import XCTest
import AppKit
import PadInkCore
@testable import PadInkMacKit

final class EcruNativeZoomTests: XCTestCase {
 func testPublicEventRoundTripsThroughAppKitWithoutModifierOrOrdinaryScroll() throws {
  for phase in [TouchPhase.began, .changed, .ended, .cancelled] {
   let cg = try EcruNativeZoom.event(logDelta: log(1.013), phase: phase, point: CGPoint(x: -123.5, y: 340.25))
   let event = try XCTUnwrap(NSEvent(cgEvent: cg))
   let restored = try XCTUnwrap(event.cgEvent)
   XCTAssertEqual(event.type, .scrollWheel)
   XCTAssertEqual(event.scrollingDeltaX, 0); XCTAssertEqual(event.scrollingDeltaY, 0)
   XCTAssertTrue(event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty)
   XCTAssertEqual(restored.getIntegerValueField(.eventSourceUserData), EcruNativeZoom.marker)
   XCTAssertEqual(Double(restored.getIntegerValueField(.scrollWheelEventPointDeltaAxis3)) / 1_000_000, log(1.013), accuracy: 0.0000005)
   XCTAssertEqual(restored.location.x, -123.5); XCTAssertEqual(restored.location.y, 340.25)
  }
 }
 func testNativeLifecyclePinsTargetCancelsOnceAndRejectsLateSamples() throws {
  let ax = AXUIElementCreateApplication(getpid())
  let target = ZoomTargetSnapshot(revision: 4, pid: getpid(), family: .ecru, app: ax, window: ax)
  let context = ZoomActionContext(input: InputContext(attachmentID: UUID(), generation: 1), gestureID: 42, geometryGeneration: 1, targetRevision: 4, target: target)
  var output: [CGEvent] = [], valid = true
  let native = EcruNativeZoom(post: { event, pid in XCTAssertEqual(pid, getpid()); output.append(event) }, validate: { _, _ in if !valid { throw ZoomFailure.changedTarget } })
  func send(_ phase: TouchPhase, delta: Float = 0, kind: TouchKind = .magnify) throws {
   try native.receive(TouchEvent(gestureID: 42, sequence: 1, timestamp: 1, geometryGeneration: 1, kind: kind, phase: phase, x: 0.25, y: 0.75, dx: delta), context: context, bounds: CGRect(x: -900, y: 100, width: 800, height: 600))
  }
  try send(.began); try send(.changed, delta: 0.02)
  XCTAssertEqual(output.last?.location, CGPoint(x: -700, y: 550))
  native.cancel(); native.cancel(); try send(.changed, delta: 0.02)
  XCTAssertEqual(output.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [1, 2, 8])
  try send(.began); valid = false
  XCTAssertThrowsError(try send(.changed, delta: 0.1))
  XCTAssertEqual(output.suffix(2).map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) }, [1, 8])
  valid = true
  try send(.began, kind: .scroll); try send(.changed, delta: 0.8, kind: .scroll); try send(.ended, kind: .scroll)
  XCTAssertEqual(output.suffix(3).map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis3) }, [0, 0, 0], "pan uses moving center, never interprets dx as zoom")

 }
 func testInvalidDemandIsRejectedAndBundleMatchingIsExact() {
  for delta in [Double.nan, .infinity, -1.1, 1.1] {
   XCTAssertThrowsError(try EcruNativeZoom.event(logDelta: delta, phase: .changed, point: .zero))
  }
  XCTAssertEqual(ApplicationFamily(bundle: "local.leafink.reader.development"), .ecru)
  XCTAssertEqual(ApplicationFamily(bundle: "local.ecru.reader.development"), .ecru)
  XCTAssertEqual(ApplicationFamily(bundle: "local.ecru.reader.development.other"), .generic)
  XCTAssertEqual(ApplicationFamily(bundle: "local.leafink.reader.development.other"), .generic)
  XCTAssertEqual(ApplicationFamily(bundle: "com.goodnotes.mac"), .goodnotes)
 }
}
#endif
