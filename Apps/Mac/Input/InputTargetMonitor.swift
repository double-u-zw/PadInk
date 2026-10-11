#if os(macOS)
import AppKit
import PadInkCore

/// Main-run-loop AX notifications, never a WindowServer lookup on the injection path.
/// Only object identity is retained; no title, document, URL or content is read.
final class InputTargetMonitor {
 private let lock = NSLock()
 private var revision: UInt64 = 0, snapshot: ZoomTargetSnapshot?
 private var pid: pid_t?, family = ApplicationFamily.generic
 var zoomTarget: (revision: UInt64, snapshot: ZoomTargetSnapshot?) { lock.lock(); defer { lock.unlock() }; return (revision, snapshot) }
 var currentRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return revision }
 var onChange: ((UInt64) -> Void)?
 private var observer: AXObserver?, app: AXUIElement?, window: AXUIElement?
 private var activation: NSObjectProtocol?, termination: NSObjectProtocol?, poll: Timer?
 func start() {
  precondition(Thread.isMainThread)
  activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.watchFrontApplication() }
  termination = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshWindow() }
  // A cheap AX fallback also covers apps that do not implement destroyed notifications.
  poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshWindow() }
  watchFrontApplication()
 }
 func stop() {
  precondition(Thread.isMainThread)
  if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
  if let termination { NSWorkspace.shared.notificationCenter.removeObserver(termination) }
  activation = nil; termination = nil; poll?.invalidate(); poll = nil; clearObserver()
 }
 private func clearObserver() {
  if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
  observer = nil; app = nil; window = nil; pid = nil
 }
 private func changed() {
  lock.lock(); revision &+= 1; let next = revision
  snapshot = nil
  if let pid, let app, let window { snapshot = ZoomTargetSnapshot(revision: next, pid: pid, family: family, app: app, window: window) }
  lock.unlock(); onChange?(next)
 }
 private func watchFrontApplication() {
  clearObserver(); changed()
  guard AXIsProcessTrusted(), let running = NSWorkspace.shared.frontmostApplication else { return }
  let pid = running.processIdentifier; self.pid = pid; family = ApplicationFamily(bundle: running.bundleIdentifier ?? "")
  let app = AXUIElementCreateApplication(pid); self.app = app
  AXUIElementSetMessagingTimeout(app, 0.05)
  var observer: AXObserver?
  if AXObserverCreate(pid, { _, element, name, context in
   guard let context else { return }
   let owner = Unmanaged<InputTargetMonitor>.fromOpaque(context).takeUnretainedValue()
   if name as String == kAXUIElementDestroyedNotification, let window = owner.window, CFEqual(element, window) { owner.window = nil; owner.changed() }
   owner.refreshWindow()
  }, &observer) == .success, let observer {
   self.observer = observer
   let context = Unmanaged.passUnretained(self).toOpaque()
   AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, context)
   CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
  }
  refreshWindow()
 }
 private func refreshWindow() {
  guard let app else { if AXIsProcessTrusted() { watchFrontApplication() }; return }
  var value: CFTypeRef?
  let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
  let next: AXUIElement? = result == .success && value.map({ CFGetTypeID($0) == AXUIElementGetTypeID() }) == true ? (value as! AXUIElement) : nil
  if let next, let window, CFEqual(next, window) { return }
  if next == nil && window == nil { return }
  if let observer, let window { AXObserverRemoveNotification(observer, window, kAXUIElementDestroyedNotification as CFString) }
  window = next; changed()
  if let observer, let next { AXObserverAddNotification(observer, next, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque()) }
 }
}
#endif
