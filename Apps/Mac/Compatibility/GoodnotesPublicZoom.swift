#if os(macOS)
import AppKit
import PadInkCore

/// Goodnotes documents Command + mouse wheel as a public zoom control.
/// Command is explicit on zoom events; ordinary scroll independently clears modifiers.
enum GoodnotesPublicZoom {
 static let documentIdentifier = "document_content_area"
 private static func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
  var value: CFTypeRef?; return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
 }
 static func contextAllowed(documentCount: Int, focusedRole: String?, hasModal: Bool) -> Bool {
  guard documentCount == 1, !hasModal, let focusedRole else { return false }
  return ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, kAXMenuRole, kAXMenuItemRole].contains(focusedRole)
 }
 static func focusRole(in app: AXUIElement) -> String? {
  guard let raw = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
  return attribute(raw as! AXUIElement, kAXRoleAttribute) as? String
 }
 static func canvas(in window: AXUIElement, app: AXUIElement, permit: ZoomPermit) throws -> AXUIElement {
  var modal = false
  let scan = try ZoomMenuScan.collect(window, permit: permit, equal: { CFEqual($0, $1) }) { node, token in
   let role = attribute(node, kAXRoleAttribute) as? String, subrole = attribute(node, kAXSubroleAttribute) as? String
   if role == kAXSheetRole || role == "AXPopover" || subrole == kAXDialogSubrole { modal = true }
   let document = attribute(node, kAXIdentifierAttribute) as? String == documentIdentifier
   return (document ? ZoomMenuItem(token: token, identifier: documentIdentifier) : nil, attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
  }
  guard contextAllowed(documentCount: scan.items.count, focusedRole: focusRole(in: app), hasModal: modal),
    let token = scan.items.first?.token, let node = scan.elements[token], anchor(of: node) != nil else { throw ZoomFailure.noZoomCommand }
  return node
 }
 static func anchor(of canvas: AXUIElement) -> CGPoint? {
  guard let rawPosition = attribute(canvas, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
    let rawSize = attribute(canvas, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
  var position = CGPoint.zero, size = CGSize.zero
  guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position), AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
    position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
  return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
 }
 /// Validate cached canvas identities directly; no full AX tree scan on each pixel frame.
 /// The reader seam is the real validator's input, never a second implementation.
 static func validatedAnchor(of canvas: AXUIElement, window: AXUIElement, app: AXUIElement, permit: ZoomPermit,
   read: (AXUIElement, String) -> CFTypeRef? = { node, key in
    AXUIElementSetMessagingTimeout(node, 0.01)
    return attribute(node, key)
   }) throws -> CGPoint {
  func value(_ node: AXUIElement, _ key: String) throws -> CFTypeRef? {
   guard permit.current else { throw ZoomFailure.cancelled }
   let result = read(node, key)
   guard permit.current else { throw ZoomFailure.cancelled }
   return result
  }
  func element(_ raw: CFTypeRef?) -> AXUIElement? {
   guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
   return (raw as! AXUIElement)
  }
  func reachesWindow(_ node: AXUIElement) throws {
   var current = node, visited: [AXUIElement] = []
   for _ in 0..<16 {
    guard !visited.contains(where: { CFEqual($0, current) }) else { throw ZoomFailure.changedTarget }
    visited.append(current)
    let role = try value(current, kAXRoleAttribute) as? String, subrole = try value(current, kAXSubroleAttribute) as? String
    let modal = try value(current, kAXModalAttribute) as? NSNumber
    guard ![kAXSheetRole, "AXPopover", kAXMenuRole, kAXMenuItemRole, "AXDrawer"].contains(role ?? ""),
      subrole != kAXDialogSubrole, modal?.boolValue != true else { throw ZoomFailure.changedTarget }
    guard role != kAXWindowRole || CFEqual(current, window) else { throw ZoomFailure.changedTarget }
    if CFEqual(current, window) { return }
    guard let parent = element(try value(current, kAXParentAttribute)) else { throw ZoomFailure.changedTarget }
    current = parent
   }
   throw ZoomFailure.changedTarget
  }
  guard let focusedWindow = element(try value(app, kAXFocusedWindowAttribute)), CFEqual(focusedWindow, window),
    try value(canvas, kAXIdentifierAttribute) as? String == documentIdentifier,
    let focus = element(try value(app, kAXFocusedUIElementAttribute)),
    contextAllowed(documentCount: 1, focusedRole: try value(focus, kAXRoleAttribute) as? String,
      hasModal: (try value(window, kAXModalAttribute) as? NSNumber)?.boolValue == true) else { throw ZoomFailure.changedTarget }
  if let owner = element(try value(canvas, kAXWindowAttribute)) {
   guard CFEqual(owner, window) else { throw ZoomFailure.changedTarget }
  } else { try reachesWindow(canvas) }
  if let top = element(try value(focus, kAXTopLevelUIElementAttribute)) {
   guard CFEqual(top, window) else { throw ZoomFailure.changedTarget }
  }
  try reachesWindow(focus)
  guard let rawPosition = try value(canvas, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
    let rawSize = try value(canvas, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { throw ZoomFailure.changedTarget }
  var position = CGPoint.zero, size = CGSize.zero
  guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position), AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
    position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw ZoomFailure.changedTarget }
  return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
 }
 /// Stateless pixel increments: no trackpad momentum or lifecycle tail is generated.
 static func pixelEvent(_ delta: Int32, at point: CGPoint) throws -> CGEvent {
  guard delta != 0, point.x.isFinite, point.y.isFinite else { throw ZoomFailure.unavailable }
  guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel,
    wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { throw ZoomFailure.executionUnconfirmed }
  event.location = point; event.flags = .maskCommand
  event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
  event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
  event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
  return event
 }
 static func event(_ command: ZoomCommand, at point: CGPoint) throws -> CGEvent {
  guard command != .reset, point.x.isFinite, point.y.isFinite else { throw ZoomFailure.unavailable }
  guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line, wheelCount: 1,
    wheel1: command == .zoomIn ? -1 : 1, wheel2: 0, wheel3: 0) else { throw ZoomFailure.executionUnconfirmed }
  event.location = point; event.flags = .maskCommand; return event
 }
}
#endif
