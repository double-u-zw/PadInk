import XCTest
import AppKit
@testable import PadInkMacKit

final class PowerPointZoomTests: XCTestCase {
 func testPublicZoomCanBeReadWhenStandardWindowIdentityIsMissing() throws {
  XCTAssertThrowsError(try PowerPointZoom.parseRead("missing value|110")) { error in
   guard case ZoomFailure.missingWindowIdentity = error else { return XCTFail("Expected public slider fallback, got \(error)") }
  }
  let valid = try PowerPointZoom.parseRead("42|110")
  XCTAssertEqual(valid.id, 42); XCTAssertEqual(valid.zoom, 110)
 }
 func testMalformedOrOutOfRangeZoomNeverBecomesAValidTarget() {
  for response in ["42", "42|4000", "42|nan", "42|100|200", "0|100", "-1|100", "unknown|100"] {
   XCTAssertThrowsError(try PowerPointZoom.parseRead(response))
  }
 }
 func testPublicSliderRequiresPercentageAndBothActions() {
  let actions = [kAXIncrementAction, kAXDecrementAction]
  XCTAssertTrue(ZoomSliderMetadata.usable(description: "110%", enabled: true, actions: actions))
  for value in ["1033", "50", "nan%", "1000%", "Volume", ""] {
   XCTAssertFalse(ZoomSliderMetadata.usable(description: value, enabled: true, actions: actions))
  }
  XCTAssertFalse(ZoomSliderMetadata.usable(description: "110%", enabled: false, actions: actions))
  XCTAssertFalse(ZoomSliderMetadata.usable(description: "110%", enabled: true, actions: [kAXIncrementAction]))
 }
 func testDiagnosticFailureDoesNotIncludeAppOrDocumentContent() {
  XCTAssertEqual(ZoomFailure.scriptError(-1700).diagnosticCode, "scriptError-1700")
  XCTAssertEqual(ZoomFailure.noZoomCommand.diagnosticCode, "noZoomCommand")
 }
}
