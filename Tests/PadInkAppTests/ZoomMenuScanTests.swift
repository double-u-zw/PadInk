import XCTest
import PadInkCore
@testable import PadInkMacKit
final class ZoomMenuScanTests: XCTestCase {
 private func deepScan(duplicate: Bool = false) throws -> [ZoomMenuItem] {
  try ZoomMenuScan.collect(0, permit: ZoomPermit(), equal: ==) { node, token in
   if node == 0 { return (nil, [100, 101, 1]) }
   if node == 100 { return (ZoomMenuItem(token: token, character: "+", modifiers: 0), []) }
   if node == 101 { return (ZoomMenuItem(token: token, character: "-", modifiers: 0), []) }
   if node < 12 { return (nil, [node + 1]) }
   return (duplicate ? ZoomMenuItem(token: token, character: "=", modifiers: 0) : nil, [])
  }.items
 }
 func testDeepUnrelatedMenuDoesNotDisableAvailableZoom() throws {
  let items = try deepScan()
  XCTAssertNotNil(ZoomMenuMatcher.match(.zoomIn, family: .chrome, items: items))
  XCTAssertNotNil(ZoomMenuMatcher.match(.zoomOut, family: .chrome, items: items))
 }
 func testDeepDuplicateStillMakesShortcutAmbiguous() throws {
  XCTAssertNil(ZoomMenuMatcher.match(.zoomIn, family: .chrome, items: try deepScan(duplicate: true)))
 }
 func testNodeAndTimeLimitsStillRefuseIncompleteScan() {
  XCTAssertThrowsError(try ZoomMenuScan.collect(0, permit: ZoomPermit(), equal: ==) { node, _ in (nil, node == 0 ? Array(1...701) : []) })
  var now: UInt64 = 0
  XCTAssertThrowsError(try ZoomMenuScan.collect(0, permit: ZoomPermit(), clock: { now }, equal: ==) { _, _ in now = 800_000_000; return (nil, []) })
 }
 func testCycleAndCancellationCannotTriggerUnboundedWork() throws {
  let result = try ZoomMenuScan.collect(0, permit: ZoomPermit(), equal: ==) { node, _ in (nil, [1 - node]) }
  XCTAssertEqual(result.visited, 2)
  let permit = ZoomPermit(); permit.cancel()
  XCTAssertThrowsError(try ZoomMenuScan.collect(0, permit: permit, equal: ==) { _, _ in XCTFail("Cancelled scan must not read"); return (nil, []) })
 }
}
