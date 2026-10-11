#if os(macOS)
import AppKit
import PadInkCore

/// cancel and the final claim share this gate. The lock is never held across an external call.
final class ZoomPermit: @unchecked Sendable {
 private final class Gate { let lock = NSLock(); var valid = true }
 private let gate: Gate
 let context: ZoomActionContext?, jobID: UUID?
 private let report: (String, UInt64) -> Void
 private let expiresAt: UInt64?, clock: () -> UInt64
 init(context: ZoomActionContext? = nil) { self.context = context; jobID = nil; gate = Gate(); report = { _, _ in }; expiresAt = nil; clock = { MonotonicClock.now } }
 private init(_ owner: ZoomPermit, jobID: UUID, expiresAt: UInt64?, clock: @escaping () -> UInt64, report: @escaping (String, UInt64) -> Void) {
  context = owner.context; gate = owner.gate; self.jobID = jobID; self.report = report; self.expiresAt = expiresAt; self.clock = clock
 }
 func forJob(_ id: UUID, expiresAt: UInt64? = nil, clock: @escaping () -> UInt64 = { MonotonicClock.now }, report: @escaping (String, UInt64) -> Void) -> ZoomPermit {
  ZoomPermit(self, jobID: id, expiresAt: expiresAt, clock: clock, report: report)
 }
 private var fresh: Bool { expiresAt.map { clock() <= $0 } ?? true }
 var current: Bool { gate.lock.lock(); defer { gate.lock.unlock() }; return gate.valid && fresh }
 func cancel() { gate.lock.lock(); gate.valid = false; gate.lock.unlock() }
 /// All slow preparation and target checks precede this boundary. A successful claim owns this
 /// one call even if cancellation follows; it cannot grant the next call after cancellation.
 func invoke<T>(post: Bool = false, _ operation: () throws -> T) throws -> T {
  gate.lock.lock(); let claimed = gate.valid && fresh; gate.lock.unlock()
  guard claimed else { throw ZoomFailure.cancelled }
  let claimedAt = MonotonicClock.now
  // Observation happens after return, using captured boundary time: diagnostic work cannot
  // delay an already claimed external call. No lock, queue or probe is held across it.
  defer {
   report("claimed", claimedAt)
   if post { report("postInvoked", claimedAt) }
   report("commandReturned", MonotonicClock.now)
  }
  return try operation()
 }
}

/// Captured on the target monitor's main run loop, before the probe is queued.
/// Retains AX identities only. It does not promise an OS-atomic target transaction.
struct ZoomTargetSnapshot {
 let revision: UInt64, pid: pid_t, family: ApplicationFamily, app: AXUIElement, window: AXUIElement
}
enum ZoomFailure: Error {
 case unavailable, changedTarget, cancelled, automationDenied, executionUnconfirmed
 case noFocusedWindow, menuScanIncomplete, noZoomCommand, missingWindowIdentity, scriptError(Int)
 var diagnosticCode: String {
  switch self {
  case .unavailable: return "unavailable"
  case .changedTarget: return "changedTarget"
  case .cancelled: return "cancelled"
  case .automationDenied: return "automationDenied"
  case .executionUnconfirmed: return "executionUnconfirmed"
  case .noFocusedWindow: return "noFocusedWindow"
  case .menuScanIncomplete: return "menuScanIncomplete"
  case .noZoomCommand: return "noZoomCommand"
  case .missingWindowIdentity: return "missingWindowIdentity"
  case .scriptError(let code): return "scriptError" + String(code)
  }
 }
}
protocol ApplicationZoomContext {
 var strategy: String { get }
 var family: ApplicationFamily { get }
 var capabilities: ApplicationCapabilities { get }
 var supportsContinuousZoom: Bool { get }
 func executePixelZoom(_ delta: Int32, permit: ZoomPermit) throws
 func execute(_ command: ZoomCommand, permit: ZoomPermit) throws
}

extension ApplicationZoomContext {
 var supportsContinuousZoom: Bool { false }
 func executePixelZoom(_ delta: Int32, permit: ZoomPermit) throws { throw ZoomFailure.unavailable }
 var strategy: String { family.rawValue + (family == .powerpoint ? "AppleScript" : "AXMenu") }
}

/// Bounds work by nodes and elapsed time, including descendants unrelated to zoom.
/// Complete traversal is required before a shortcut can be declared unique.
enum ZoomMenuScan {
 static func collect<Node>(_ root: Node, permit: ZoomPermit, clock: () -> UInt64 = { MonotonicClock.now },
   equal: (Node, Node) -> Bool, read: (Node, Int) throws -> (ZoomMenuItem?, [Node])) throws -> (items: [ZoomMenuItem], elements: [Int: Node], visited: Int, elapsed: UInt64) {
  var items: [ZoomMenuItem] = [], elements: [Int: Node] = [:], visited: [Node] = []
  let started = clock()
  var pending = [root]
  while let node = pending.popLast() {
   guard permit.current else { throw ZoomFailure.cancelled }
   if visited.contains(where: { equal($0, node) }) { continue }
   guard visited.count < 700, clock() - started < 800_000_000 else { throw ZoomFailure.menuScanIncomplete }
   visited.append(node)
   let (item, children) = try read(node, items.count)
   if let item { items.append(item); elements[item.token] = node }
   pending.append(contentsOf: children.reversed())
  }
  guard permit.current else { throw ZoomFailure.cancelled }
  guard clock() - started < 800_000_000 else { throw ZoomFailure.menuScanIncomplete }
  return (items, elements, visited.count, clock() - started)
 }
}

/// Captures only AX object identities and shortcut metadata, never window/document titles.
final class ApplicationZoomTarget: ApplicationZoomContext {
 let family: ApplicationFamily, capabilities: ApplicationCapabilities
 private let pid: pid_t, app: AXUIElement, window: AXUIElement
 private let commands: [ZoomCommand: AXUIElement], scriptWindowID: Int?
 private let slider: AXUIElement?, goodnotesCanvas: AXUIElement?
 private let pixelEventReport: (CGEvent, ZoomPermit) -> Void
 var supportsContinuousZoom: Bool { goodnotesCanvas != nil }
 var strategy: String {
  goodnotesCanvas != nil ? "goodnotesContinuousCommandPixel" : slider != nil ? "powerpointAXSlider" : family.rawValue + (scriptWindowID != nil ? "AppleScript" : "AXMenu")
 }
 private init(family: ApplicationFamily, pid: pid_t, app: AXUIElement, window: AXUIElement, commands: [ZoomCommand: AXUIElement], scriptWindowID: Int?, slider: AXUIElement?, goodnotesCanvas: AXUIElement?, pixelEventReport: @escaping (CGEvent, ZoomPermit) -> Void) {
  self.family = family; self.pid = pid; self.app = app; self.window = window; self.commands = commands; self.scriptWindowID = scriptWindowID; self.slider = slider; self.goodnotesCanvas = goodnotesCanvas; self.pixelEventReport = pixelEventReport
  var c = ApplicationCapabilities(); c.pencil = family == .powerpoint || family == .preview || family == .goodnotes
  c.zoomIn = goodnotesCanvas != nil || scriptWindowID != nil || slider != nil || commands[.zoomIn] != nil; c.zoomOut = goodnotesCanvas != nil || scriptWindowID != nil || slider != nil || commands[.zoomOut] != nil; c.resetZoom = scriptWindowID != nil || commands[.reset] != nil; capabilities = c
 }
 private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? { var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil }
 private static func element(_ value: CFTypeRef?) -> AXUIElement? { guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }; return (value as! AXUIElement) }
 static func probe(_ permit: ZoomPermit, pixelEventReport: @escaping (CGEvent, ZoomPermit) -> Void = { _, _ in }, report: (String, Double?) -> Void = { _, _ in }) throws -> ApplicationZoomTarget {
  guard permit.current, AXIsProcessTrusted(), let pinned = permit.context?.target,
    pinned.revision == permit.context?.targetRevision else { throw ZoomFailure.unavailable }
  let family = pinned.family, pid = pinned.pid
  report("family." + family.rawValue, nil)
  let app = pinned.app, window = pinned.window; AXUIElementSetMessagingTimeout(app, 0.05)
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
    let focused = element(attribute(app, kAXFocusedWindowAttribute)), CFEqual(focused, window) else { throw ZoomFailure.changedTarget }
  var commands: [ZoomCommand: AXUIElement] = [:], scriptID: Int?, slider: AXUIElement?, goodnotesCanvas: AXUIElement?
  if family == .goodnotes {
   goodnotesCanvas = try GoodnotesPublicZoom.canvas(in: window, app: app, permit: permit)
   report("goodnotes.documentCommandScroll", nil)
  }
  else if family == .powerpoint {
   do { scriptID = try PowerPointZoom.read(permit: permit).id }
   catch ZoomFailure.missingWindowIdentity {
    report("powerpoint.missingWindowIdentity", nil)
    let scanned = try ZoomMenuScan.collect(window, permit: permit, equal: { CFEqual($0, $1) }) { node, token in
     var actions: CFArray?; _ = AXUIElementCopyActionNames(node, &actions)
     let valid = attribute(node, kAXRoleAttribute) as? String == kAXSliderRole &&
       ZoomSliderMetadata.usable(description: attribute(node, kAXValueDescriptionAttribute) as? String,
         enabled: (attribute(node, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? false, actions: actions as? [String] ?? [])
     return (valid ? ZoomMenuItem(token: token, identifier: "slider", enabled: true) : nil, attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    guard scanned.items.count == 1, let token = scanned.items.first?.token else { throw ZoomFailure.noZoomCommand }
    slider = scanned.elements[token]; report("powerpoint.publicSlider", nil)
   }
  }
  else if let bar = element(attribute(app, kAXMenuBarAttribute)) {
   let scanned = try ZoomMenuScan.collect(bar, permit: permit, equal: { CFEqual($0, $1) }) { node, token in
    let item = attribute(node, kAXRoleAttribute) as? String == kAXMenuItemRole ?
     ZoomMenuItem(token: token, identifier: attribute(node, kAXIdentifierAttribute) as? String,
       character: attribute(node, kAXMenuItemCmdCharAttribute) as? String, modifiers: (attribute(node, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue,
       enabled: (attribute(node, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? false) : nil
    return (item, attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
   }
   report("menu.nodes", Double(scanned.visited)); report("menu.milliseconds", Double(scanned.elapsed) / 1e6)
   let items = scanned.items, elements = scanned.elements
   for command in ZoomCommand.allCases { if let token = ZoomMenuMatcher.match(command, family: family, items: items) { commands[command] = elements[token] } }
  }
  report("menu.commands", Double(commands.count))
  let target = ApplicationZoomTarget(family: family, pid: pid, app: app, window: window, commands: commands, scriptWindowID: scriptID, slider: slider, goodnotesCanvas: goodnotesCanvas, pixelEventReport: pixelEventReport)
  try target.recheck(permit); guard target.capabilities.zoomIn || target.capabilities.zoomOut else { throw ZoomFailure.noZoomCommand }; return target
 }
 private func recheck(_ permit: ZoomPermit) throws {
  guard permit.current else { throw ZoomFailure.cancelled }
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let focused = Self.element(Self.attribute(app, kAXFocusedWindowAttribute)), CFEqual(focused, window) else { throw ZoomFailure.changedTarget }
 }
 /// The product Goodnotes path and no-side-effect sink tests share this exact final boundary.
 static func post(_ event: CGEvent, permit: ZoomPermit, postEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) throws {
  try permit.invoke(post: true) { postEvent(event) }
 }
 func executePixelZoom(_ delta: Int32, permit: ZoomPermit) throws {
  guard let goodnotesCanvas else { throw ZoomFailure.unavailable }
  try recheck(permit)
  let point = try GoodnotesPublicZoom.validatedAnchor(of: goodnotesCanvas, window: window, app: app, permit: permit)
  let event = try GoodnotesPublicZoom.pixelEvent(delta, at: point)
  try recheck(permit)
  try Self.post(event, permit: permit)
  pixelEventReport(event, permit)
 }
 func execute(_ command: ZoomCommand, permit: ZoomPermit) throws {
  try recheck(permit)
  if let goodnotesCanvas {
   let current = try GoodnotesPublicZoom.canvas(in: window, app: app, permit: permit)
   guard CFEqual(current, goodnotesCanvas), let point = GoodnotesPublicZoom.anchor(of: current) else { throw ZoomFailure.changedTarget }
   let event = try GoodnotesPublicZoom.event(command, at: point)
   try recheck(permit); try Self.post(event, permit: permit); return
  }
  if let slider {
   guard command != .reset else { throw ZoomFailure.unavailable }
   var actions: CFArray?; _ = AXUIElementCopyActionNames(slider, &actions)
   guard ZoomSliderMetadata.usable(description: Self.attribute(slider, kAXValueDescriptionAttribute) as? String,
     enabled: (Self.attribute(slider, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? false, actions: actions as? [String] ?? []) else { throw ZoomFailure.unavailable }
   try recheck(permit)
   guard try permit.invoke({ AXUIElementPerformAction(slider, (command == .zoomIn ? kAXIncrementAction : kAXDecrementAction) as CFString) }) == .success else { throw ZoomFailure.executionUnconfirmed }
   return
  }
  if let scriptWindowID { try PowerPointZoom.execute(command, windowID: scriptWindowID, permit: permit, validate: { try self.recheck(permit) }); return }
  guard let item = commands[command], (Self.attribute(item, kAXEnabledAttribute) as? NSNumber)?.boolValue == true else { throw ZoomFailure.unavailable }
  let metadata = ZoomMenuItem(token: 0, identifier: Self.attribute(item, kAXIdentifierAttribute) as? String, character: Self.attribute(item, kAXMenuItemCmdCharAttribute) as? String, modifiers: (Self.attribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue)
  guard ZoomMenuMatcher.match(command, family: family, items: [metadata]) == 0 else { throw ZoomFailure.unavailable }
  try recheck(permit)
  guard try permit.invoke({ AXUIElementPerformAction(item, kAXPressAction as CFString) }) == .success else { throw ZoomFailure.executionUnconfirmed }
 }
}

enum ZoomSliderMetadata {
 static func usable(description: String?, enabled: Bool, actions: [String]) -> Bool {
  guard enabled, let text = description?.trimmingCharacters(in: .whitespacesAndNewlines), text.hasSuffix("%"),
    let percentage = Double(text.dropLast()), percentage.isFinite, (10...400).contains(percentage) else { return false }
  return actions.contains(kAXIncrementAction) && actions.contains(kAXDecrementAction)
 }
}

/// PowerPoint's shipped public scripting dictionary defines window ID, normal view and view.zoom.
/// The script checks the target ID inside the Apple event operation and returns the actual ratio.
enum PowerPointZoom {
 struct State { let id: Int, zoom: Int }
 static func script(_ body: String, permit: ZoomPermit, mutating: Bool = false) throws -> String {
  guard permit.current else { throw ZoomFailure.cancelled }
  let p = Process(), out = Pipe(), err = Pipe(), done = DispatchSemaphore(value: 0)
  p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  p.arguments = ["-e", "with timeout of 1 second\ntell application id \"com.microsoft.Powerpoint\"\ntell active window\nif view type is not normal view then error \"unsupported view\"\n\(body)\nend tell\nend tell\nend timeout"]
  p.standardOutput = out; p.standardError = err; p.terminationHandler = { _ in done.signal() }
  let run = { () throws -> String in
   try p.run()
   if done.wait(timeout: .now() + 2) == .timedOut { p.terminate(); throw ZoomFailure.executionUnconfirmed }
   if p.terminationStatus != 0 {
    let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let numeric = message.range(of: #"\(-?\d+\)\s*$"#, options: .regularExpression).flatMap { Int(message[$0].trimmingCharacters(in: CharacterSet(charactersIn: "() \n\r"))) } ?? 0
    throw numeric == -1743 ? ZoomFailure.automationDenied : ZoomFailure.scriptError(numeric)
   }
   return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  // Process preparation is complete. Claim immediately precedes launch; the one claimed script
  // is allowed to finish, with commandReturned recorded after its response rather than launch.
  if mutating { return try permit.invoke { try run() } }
  guard permit.current else { throw ZoomFailure.cancelled }; return try run()

 }
 static func read(permit: ZoomPermit) throws -> State {
  return try parseRead(script("return (id as text) & \"|\" & (zoom of its view as text)", permit: permit))
 }
 static func parseRead(_ response: String) throws -> State {
  let text = response.split(separator: "|", omittingEmptySubsequences: false)
  guard text.count == 2, let zoom = Int(text[1]), (10...400).contains(zoom) else { throw ZoomFailure.unavailable }
  if text[0] == "missing value" || text[0].isEmpty { throw ZoomFailure.missingWindowIdentity }
  guard let id = Int(text[0]), id > 0 else { throw ZoomFailure.unavailable }
  return State(id: id, zoom: zoom)
 }
 static func execute(_ command: ZoomCommand, windowID: Int, permit: ZoomPermit, validate: () throws -> Void) throws {
  let old = try read(permit: permit); guard old.id == windowID else { throw ZoomFailure.changedTarget }
  let ratio = command == .reset ? 100 : max(10, min(400, old.zoom + (command == .zoomIn ? 10 : -10)))
  guard permit.current else { throw ZoomFailure.cancelled }
  try validate()
  let result = try script("if id is not \(windowID) or zoom of its view is not \(old.zoom) then error \"target changed\"\nset zoom of its view to \(ratio)\nreturn zoom of its view", permit: permit, mutating: true)
  guard Int(result) == ratio else { throw ZoomFailure.executionUnconfirmed }
 }
}

#endif
