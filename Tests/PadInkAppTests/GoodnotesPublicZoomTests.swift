import XCTest
import AppKit
import PadInkCore
@testable import PadInkMacKit

final class GoodnotesPublicZoomTests: XCTestCase {
 func testDocumentCanvasAllowsPublicWheelWithoutMenuCommand() {
  XCTAssertTrue(GoodnotesPublicZoom.contextAllowed(documentCount: 1, focusedRole: kAXStaticTextRole, hasModal: false))
  XCTAssertTrue(GoodnotesPublicZoom.contextAllowed(documentCount: 1, focusedRole: kAXButtonRole, hasModal: false))
 }
 func testMissingAmbiguousOrModalDocumentNeverReceivesZoom() {
  for count in [0, 2] { XCTAssertFalse(GoodnotesPublicZoom.contextAllowed(documentCount: count, focusedRole: kAXStaticTextRole, hasModal: false)) }
  XCTAssertFalse(GoodnotesPublicZoom.contextAllowed(documentCount: 1, focusedRole: kAXStaticTextRole, hasModal: true))
  XCTAssertFalse(GoodnotesPublicZoom.contextAllowed(documentCount: 1, focusedRole: nil, hasModal: false))
 }
 func testEditableOrMenuFocusNeverReceivesZoom() {
  for role in [kAXTextFieldRole,kAXTextAreaRole,kAXComboBoxRole,kAXMenuRole,kAXMenuItemRole] {
   XCTAssertFalse(GoodnotesPublicZoom.contextAllowed(documentCount: 1, focusedRole: role, hasModal: false))
  }
 }
 func testGoodnotesZoomInUsesNegativeWheelAndOutPositiveWithPerEventCommandFlag() throws {
  let p = CGPoint(x: 640, y: 480), up = try GoodnotesPublicZoom.event(.zoomIn, at: p), down = try GoodnotesPublicZoom.event(.zoomOut, at: p)
  for e in [up, down] {
   XCTAssertEqual(e.type, .scrollWheel); XCTAssertEqual(e.flags, .maskCommand); XCTAssertEqual(e.location, p)
   XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventDeltaAxis2), 0)
   XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
   XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventIsContinuous), 0)
  }
  XCTAssertEqual(up.getIntegerValueField(.scrollWheelEventDeltaAxis1), -1)
  XCTAssertLessThan(NSEvent(cgEvent: up)!.scrollingDeltaY, 0)
  XCTAssertEqual(down.getIntegerValueField(.scrollWheelEventDeltaAxis1), 1)
  XCTAssertGreaterThan(NSEvent(cgEvent: down)!.scrollingDeltaY, 0)
  XCTAssertEqual(NSEvent(cgEvent: up)?.modifierFlags.intersection(.deviceIndependentFlagsMask), .command)
 }
 func testUnsupportedResetAndInvalidPointNeverCreateAnEvent() {
  XCTAssertThrowsError(try GoodnotesPublicZoom.event(.reset, at: .zero))
  XCTAssertThrowsError(try GoodnotesPublicZoom.event(.zoomIn, at: CGPoint(x: CGFloat.nan, y: 0)))
 }
 func testCancelledCapabilityProbeNeverReadsAnUnknownTarget() {
  let permit = ZoomPermit(); permit.cancel(); let unused = AXUIElementCreateSystemWide()
  XCTAssertThrowsError(try GoodnotesPublicZoom.canvas(in: unused, app: unused, permit: permit)) { error in
   guard case ZoomFailure.cancelled = error else { return XCTFail("Expected cancellation") }
  }
 }

}
