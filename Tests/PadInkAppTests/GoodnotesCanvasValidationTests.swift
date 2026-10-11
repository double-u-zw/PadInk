import XCTest
import AppKit
import PadInkCore
@testable import PadInkMacKit

/// Exercises the product cached-canvas validator. AX objects are identity tokens only;
/// attribute reads come from metadata and never contact an application or post input.
final class GoodnotesCanvasValidationTests: XCTestCase {
 private final class Fixture {
  let app = AXUIElementCreateApplication(1_990_000_000)
  let window = AXUIElementCreateApplication(1_990_000_001)
  let canvas = AXUIElementCreateApplication(1_990_000_002)
  let focus = AXUIElementCreateApplication(1_990_000_003)
  let other = AXUIElementCreateApplication(1_990_000_004)
  let permit = ZoomPermit()
  var nodes: [AXUIElement] = []
  var metadata: [[String: CFTypeRef]] = []
  var reads: [(Int, String)] = []
  var duringRead: (AXUIElement, String) -> Void = { _, _ in }
  init() {
   for node in [app, window, canvas, focus, other] { nodes.append(node); metadata.append([:]) }
   put(app, kAXFocusedWindowAttribute, window)
   put(app, kAXFocusedUIElementAttribute, focus)
   put(window, kAXRoleAttribute, kAXWindowRole as CFString)
   put(window, kAXModalAttribute, NSNumber(value: false))
   put(canvas, kAXRoleAttribute, kAXGroupRole as CFString)
   put(canvas, kAXIdentifierAttribute, GoodnotesPublicZoom.documentIdentifier as CFString)
   put(canvas, kAXWindowAttribute, window)
   put(canvas, kAXParentAttribute, window)
   put(focus, kAXRoleAttribute, kAXStaticTextRole as CFString)
   put(focus, kAXWindowAttribute, window)
   put(focus, kAXTopLevelUIElementAttribute, window)
   put(focus, kAXParentAttribute, canvas)
   var position = CGPoint(x: 240, y: 130), size = CGSize(width: 960, height: 720)
   let rawPosition = AXValueCreate(.cgPoint, &position)!, rawSize = AXValueCreate(.cgSize, &size)!
   put(canvas, kAXPositionAttribute, rawPosition); put(canvas, kAXSizeAttribute, rawSize)
   put(focus, kAXPositionAttribute, rawPosition); put(focus, kAXSizeAttribute, rawSize)
  }
  private func index(_ node: AXUIElement) -> Int {
   guard let index = nodes.firstIndex(where: { CFEqual($0, node) }) else { preconditionFailure("unknown fixture node") }
   return index
  }
  func put(_ node: AXUIElement, _ key: String, _ value: CFTypeRef?) { metadata[index(node)][key] = value }
  func add(role: String = kAXGroupRole) -> AXUIElement {
   let node = AXUIElementCreateApplication(1_990_000_000 + Int32(nodes.count))
   nodes.append(node); metadata.append([kAXRoleAttribute: role as CFString]); return node
  }
  func read(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
   let i = index(node); reads.append((i, key)); duringRead(node, key); return metadata[i][key]
  }
  func validate() throws -> CGPoint {
   try GoodnotesPublicZoom.validatedAnchor(of: canvas, window: window, app: app, permit: permit, read: read)
  }
  func longParents(from start: AXUIElement) {
   var previous = start
   for _ in 0..<32 { let next = add(); put(previous, kAXParentAttribute, next); previous = next }
   put(previous, kAXParentAttribute, window)
  }
 }
 func testCachedCanvasKeepsTheDocumentCenterWithoutTreeEnumeration() throws {
  let f = Fixture(); XCTAssertEqual(try f.validate(), CGPoint(x: 720, y: 490))
  XCTAssertFalse(f.reads.contains { $0.1 == kAXChildrenAttribute }, "continuous batches must not rescan the AX tree")
 }
 func testCanvasWithoutAXWindowUsesItsBoundedParentIdentity() throws {
  let f = Fixture(); f.put(f.canvas, kAXWindowAttribute, nil)
  let group = f.add(); f.put(f.canvas, kAXParentAttribute, group); f.put(group, kAXParentAttribute, f.window)
  XCTAssertEqual(try f.validate(), CGPoint(x: 720, y: 490))
 }
 func testMissingFocusTopLevelStillRequiresAValidParentPath() throws {
  let f = Fixture(); f.put(f.focus, kAXTopLevelUIElementAttribute, nil)
  XCTAssertEqual(try f.validate(), CGPoint(x: 720, y: 490))
 }
 func testAChangedFocusedWindowRejectsTheCachedCanvas() {
  let f = Fixture(); f.put(f.app, kAXFocusedWindowAttribute, f.other)
  XCTAssertThrowsError(try f.validate())
 }
 func testCanvasMarkerMustStillIdentifyTheDocument() {
  for marker: CFTypeRef? in [nil, "other_control" as CFString] {
   let f = Fixture(); f.put(f.canvas, kAXIdentifierAttribute, marker); XCTAssertThrowsError(try f.validate())
  }
 }
 func testAnExplicitDifferentCanvasWindowIsNeverIgnored() {
  let f = Fixture(); f.put(f.canvas, kAXWindowAttribute, f.other)
  XCTAssertThrowsError(try f.validate(), "a correct parent cannot override an explicit different AXWindow")
 }
 func testCanvasFallbackCannotCrossAnotherWindowOrAcceptACycle() {
  for cycle in [false, true] {
   let f = Fixture(); f.put(f.canvas, kAXWindowAttribute, nil)
   f.put(f.canvas, kAXParentAttribute, cycle ? f.canvas : f.other)
   f.put(f.other, kAXRoleAttribute, kAXWindowRole as CFString)
   f.put(f.other, kAXParentAttribute, f.window)
   XCTAssertThrowsError(try f.validate())
  }
 }
 func testCanvasFallbackDepthIsBounded() {
  let f = Fixture(); f.put(f.canvas, kAXWindowAttribute, nil); f.longParents(from: f.canvas)
  XCTAssertThrowsError(try f.validate())
  XCTAssertLessThan(f.reads.count, 160, "metadata traversal must stop instead of walking arbitrary depth")
 }
 func testEditableAndMenuFocusCannotReceiveZoom() {
  for role in [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXMenuRole, kAXMenuItemRole] {
   let f = Fixture(); f.put(f.focus, kAXRoleAttribute, role as CFString); XCTAssertThrowsError(try f.validate(), role)
  }
 }
 func testMissingFocusOrItsRoleCannotReceiveZoom() {
  for removeFocus in [true, false] {
   let f = Fixture()
   if removeFocus { f.put(f.app, kAXFocusedUIElementAttribute, nil) }
   else { f.put(f.focus, kAXRoleAttribute, nil) }
   XCTAssertThrowsError(try f.validate())
  }
 }
 func testAModalWindowRejectsOtherwiseValidCanvasMetadata() {
  let f = Fixture(); f.put(f.window, kAXModalAttribute, NSNumber(value: true))
  XCTAssertThrowsError(try f.validate())
 }
 func testFocusTopLevelCannotBeASheetOrAnotherWindow() {
  for role in [kAXSheetRole, kAXWindowRole] {
   let f = Fixture(); f.put(f.other, kAXRoleAttribute, role as CFString)
   f.put(f.focus, kAXTopLevelUIElementAttribute, f.other); XCTAssertThrowsError(try f.validate())
  }
 }
 func testButtonFocusInsideSheetPopoverOrMenuIsRejectedByItsAncestor() {
  for role in [kAXSheetRole, "AXPopover", kAXMenuRole, kAXMenuItemRole] {
   let f = Fixture(); f.put(f.focus, kAXRoleAttribute, kAXButtonRole as CFString)
   let parent = f.add(role: role); f.put(f.focus, kAXParentAttribute, parent); f.put(parent, kAXParentAttribute, f.window)
   // AXWindow and top-level still point to the document window. The ancestry must be checked.
   XCTAssertThrowsError(try f.validate(), role)
  }
 }
 func testDialogOrModalAncestorCannotBeHiddenBehindAnAllowedFocusRole() {
  for modal in [true, false] {
   let f = Fixture(); let parent = f.add(); f.put(f.focus, kAXRoleAttribute, kAXButtonRole as CFString)
   f.put(f.focus, kAXParentAttribute, parent); f.put(parent, kAXParentAttribute, f.window)
   if modal { f.put(parent, kAXModalAttribute, NSNumber(value: true)) }
   else { f.put(parent, kAXSubroleAttribute, kAXDialogSubrole as CFString) }
   XCTAssertThrowsError(try f.validate())
  }
 }
 func testFocusParentCycleCannotBeAccepted() {
  let f = Fixture(); f.put(f.focus, kAXParentAttribute, f.focus); XCTAssertThrowsError(try f.validate())
 }
 func testFocusParentDepthIsBounded() {
  let f = Fixture(); f.longParents(from: f.focus); XCTAssertThrowsError(try f.validate())
  XCTAssertLessThan(f.reads.count, 160, "metadata traversal must stop instead of walking arbitrary depth")
 }
 func testMissingOrInvalidCanvasGeometryNeverProducesAnAnchor() {
  for mode in 0..<5 {
   let f = Fixture()
   switch mode {
   case 0: f.put(f.canvas, kAXPositionAttribute, nil)
   case 1: f.put(f.canvas, kAXPositionAttribute, NSNumber(value: 1))
   case 2: var position = CGPoint(x: CGFloat.nan, y: 130); f.put(f.canvas, kAXPositionAttribute, AXValueCreate(.cgPoint, &position)!)
   case 3: var size = CGSize(width: 0, height: 720); f.put(f.canvas, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
   default: var size = CGSize(width: 960, height: CGFloat.infinity); f.put(f.canvas, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
   }
   XCTAssertThrowsError(try f.validate(), "mode=\(mode)")
  }
 }
 func testCancellationBeforeValidationDoesNotReadAnyAXMetadata() {
  let f = Fixture(); f.permit.cancel()
  XCTAssertThrowsError(try f.validate()) { error in
   guard case ZoomFailure.cancelled = error else { return XCTFail("expected cancellation, got \(error)") }
  }
  XCTAssertTrue(f.reads.isEmpty)
 }
 func testCancellationDuringAttributeReadCannotReturnAnAnchor() {
  let f = Fixture()
  f.duringRead = { node, key in
   if CFEqual(node, f.canvas), key == kAXPositionAttribute { f.permit.cancel() }
  }
  XCTAssertThrowsError(try f.validate()) { error in
   guard case ZoomFailure.cancelled = error else { return XCTFail("expected cancellation, got \(error)") }
  }
 }
}
