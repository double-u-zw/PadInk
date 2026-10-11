#if os(macOS)
import AppKit
import PadInkCore

/// Passive session event tap on its own run loop. Observation is NOT application consumption.
/// No permission prompt and no keyboard or other applications' mouse data are retained.
final class InputPerformanceObserver {
 private let diagnostics: Diagnostics
 private var worker: Thread?
 init(diagnostics: Diagnostics) { self.diagnostics = diagnostics }
 func start() {
  guard diagnostics.performance.enabled, worker == nil else { return }
  let diagnostics = self.diagnostics
  let thread = Thread {
   let retained = Unmanaged.passRetained(diagnostics)
   defer { retained.release() }
   let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
   guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
    eventsOfInterest: mask, callback: { _, type, event, info in
     guard let info else { return Unmanaged.passUnretained(event) }
     let diagnostics = Unmanaged<Diagnostics>.fromOpaque(info).takeUnretainedValue()
     if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      diagnostics.performance.record(PerformanceEvent("system.tapDisabled")); return Unmanaged.passUnretained(event)
     }
     guard event.getIntegerValueField(.tabletEventDeviceID) == 0x5049 else { return Unmanaged.passUnretained(event) }
     let key = UInt64(bitPattern: event.getIntegerValueField(.eventSourceUserData))
     diagnostics.performance.record(PerformanceEvent("system.sessionTapObserved", item: key >> 32, sample: key & 0xffffffff, code: String(type.rawValue)))
     return Unmanaged.passUnretained(event)
    }, userInfo: retained.toOpaque()) else {
     diagnostics.performance.record(PerformanceEvent("system.tapUnavailable")); return
    }
   guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
   CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
   CGEvent.tapEnable(tap: tap, enable: true)
   diagnostics.performance.record(PerformanceEvent("system.tapStarted"))
   while !Thread.current.isCancelled { CFRunLoopRunInMode(.defaultMode, 0.25, false) }
   CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap)
   CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
  }
  thread.name = "pnk2.performance.observer"; worker = thread; thread.start()
 }
 func stop() { worker?.cancel(); worker = nil }
 deinit { stop() }
}
#endif
