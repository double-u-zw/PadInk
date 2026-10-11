#if os(macOS)
import AppKit
import PadInkCore

/// Pencil injection, ported from Baseline v0.1.0 TabletInputBackend — the only implementation with
/// real-device PowerPoint native-ink persistence evidence (B-003). Kept as-is: tablet proximity +
/// tablet fields, stable device identity, non-coalesced mouse events, batch time anchoring, an
/// idempotent reset that posts up + proximity-out at the last actual sample.
///
/// Changes from Baseline, all deliberate (ARCHITECTURE §14 I-10):
/// - Renamed; the validation-only InputDeliveryScheduler (60/120 Hz) is removed. RAW only.
/// - No ClockSync: batches are anchored at local `now` with actual intra-batch spacing kept
///   (Baseline's uncalibrated path, testUncalibratedBatchKeepsSampleIntervals...). Cross-device
///   clocks only feed diagnostics in 0.3.
/// - The event source state is a parameter so the replay tool can A/B `.hidSystemState` (default,
///   the product value) against 0.2.0's `.privateState`. Product code never passes another value.
/// Only this class posts Pencil CGEvents. All calls are serialized on the input queue.
public final class PencilInjectionBackend {
 public static let productSourceState: CGEventSourceStateID = .hidSystemState
 private var state = InputSession(), eventNumber: Int64 = 0
 private var lastEventTime: UInt64 = 0
 public private(set) var lastPostTime: UInt64 = 0
 private let source: CGEventSource?
 public let sourceState: CGEventSourceStateID
 private let diagnostics: Diagnostics
 private let postEvent: (CGEvent) -> Void
 private let now: () -> UInt64
 private var session: UInt64 = 0
 private var resetting = false
 public var active: Bool { state.active != nil }
 public var displayBounds: CGRect = CGDisplayBounds(CGMainDisplayID())
 public init(diagnostics: Diagnostics, sourceState: CGEventSourceStateID = PencilInjectionBackend.productSourceState, now: @escaping () -> UInt64 = { MonotonicClock.now }, postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
  self.diagnostics = diagnostics; self.sourceState = sourceState; source = CGEventSource(stateID: sourceState); self.now = now; self.postEvent = postEvent
 }
 public func begin(_ samples: [PencilSample], session: UInt64) throws { try apply(samples, session: session) }
 public func samples(_ samples: [PencilSample], session: UInt64) throws { try apply(samples, session: session) }
 public func end(_ samples: [PencilSample], session: UInt64) throws { try apply(samples, session: session) }
 public func cancel(_ samples: [PencilSample], session: UInt64) throws { try apply(samples, session: session) }
 public func reset(session: UInt64 = 0) { let anchor = state.active; resetting = true; for a in state.reset() { if let anchor { autoreleasepool { post(a, timestamp: now(), anchor: anchor) } } }; resetting = false; self.session = session }
 private func apply(_ samples: [PencilSample], session: UInt64) throws {
  guard session == self.session, session != 0 else { throw PencilSequenceError.sequence }
  let began = now()
  defer { let ended = now(); diagnostics.performance.record(PerformanceEvent("input.backend", time: ended, generation: session, item: samples.first?.stroke, sample: samples.first?.sequence, start: began, end: ended, count: samples.count)) }
  let actions = try state.consume(samples)
  for s in samples { diagnostics.mark("input.validate", session: session, sample: s, state: "accepted") }
  guard let first = samples.first, let last = samples.last else { return }
  let endTime = now()
  var current = first
  for (index, a) in actions.enumerated() {
   if case .proximityIn = a, index + 1 < actions.count, case .down(let s) = actions[index + 1] { current = s }
   switch a { case .down(let s), .move(let s), .up(let s): current = s; default: break }
   // Anchor the batch once; shifting the whole batch avoids flattening future-dated sample intervals.
   let distance = last.timestamp - current.timestamp
   let time = endTime >= distance ? endTime - distance : 0
   autoreleasepool { post(a, timestamp: time, anchor: current) }
  }
 }
 private func post(_ action: TabletAction, timestamp: UInt64, anchor: PencilSample) {
  // Preserve the spacing of actual coalesced samples; the native event stream never runs backwards.
  let time = max(lastEventTime, min(timestamp, now())); lastEventTime = time
  switch action {
  case .proximityIn: proximity(true, timestamp: time, anchor: anchor)
  case .proximityOut: proximity(false, timestamp: time, anchor: anchor)
  case .down(let s): eventNumber += 1; point(s, type: .leftMouseDown, contact: true, timestamp: time)
  case .move(let s): point(s, type: .leftMouseDragged, contact: true, timestamp: time)
  case .up(let s): point(s, type: .leftMouseUp, contact: false, timestamp: time)
  }
 }
 private func identity(_ e: CGEvent) {
  e.setIntegerValueField(.tabletProximityEventVendorID, value: 0)
  e.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
  e.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
  e.setIntegerValueField(.tabletProximityEventDeviceID, value: 0x5049)
  e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
  e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 0x802)
  e.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
  e.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: 0x50494e4b)
  e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x001 | 0x002 | 0x004 | 0x040 | 0x080 | 0x100 | 0x400)
  e.setIntegerValueField(.tabletProximityEventPointerType, value: 1)
 }
 private func location(for s: PencilSample) -> CGPoint { VideoGeometry.macPoint(normalized: CGPoint(x: CGFloat(s.x), y: CGFloat(s.y)), captureBounds: displayBounds) }
 private func proximity(_ entering: Bool, timestamp: UInt64, anchor: PencilSample) {
  guard let e = CGEvent(source: source) else { return }; e.type = .tabletProximity; identity(e)
  e.timestamp = timestamp; e.location = location(for: anchor)
  e.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0); postEvent(e)
  diagnostics.mark("input.proximity", session: session, sample: anchor, state: entering ? "enter" : "leave", screenX: Double(e.location.x), screenY: Double(e.location.y), eventType: e.type.rawValue)
 }
 private func point(_ s: PencilSample, type: CGEventType, contact: Bool, timestamp: UInt64) {
  let location = location(for: s)
  guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: .left) else { return }
  e.flags.insert(.maskNonCoalesced)
  e.timestamp = timestamp
  // Validation can correlate AppKit observations with the original sample.
  e.setIntegerValueField(.eventSourceUserData, value: Int64(bitPattern: (s.stroke & 0xffffffff) << 32 | (s.sequence & 0xffffffff)))
  e.setIntegerValueField(.mouseEventSubtype, value: 1)
  e.setIntegerValueField(.mouseEventNumber, value: eventNumber); e.setIntegerValueField(.mouseEventClickState, value: 1)
  e.setIntegerValueField(.tabletEventDeviceID, value: 0x5049)
  e.setIntegerValueField(.tabletEventPointX, value: Int64(s.x * 65535)); e.setIntegerValueField(.tabletEventPointY, value: Int64(s.y * 65535))
  e.setIntegerValueField(.tabletEventPointButtons, value: contact ? 1 : 0)
  let pressure = contact ? Double(s.pressure) : 0
  e.setDoubleValueField(.mouseEventPressure, value: pressure); e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
  e.setDoubleValueField(.tabletEventTiltX, value: s.tilt.0); e.setDoubleValueField(.tabletEventTiltY, value: s.tilt.1)
  diagnostics.mark("input.cgEvent", session: session, sample: s, state: resetting ? "reset" : "posted", eventTime: e.timestamp, screenX: Double(e.location.x), screenY: Double(e.location.y), eventFlags: e.flags.rawValue, eventType: e.type.rawValue)
  lastPostTime = now()
  diagnostics.performance.record(PerformanceEvent("input.postBegin", time: lastPostTime, generation: session, item: s.stroke, sample: s.sequence, code: resetting ? "reset" : "sample"))
  postEvent(e)
  let returned = now()
  diagnostics.performance.record(PerformanceEvent("input.postCall", time: returned, generation: session, item: s.stroke, sample: s.sequence, start: lastPostTime, end: returned, code: resetting ? "reset" : "sample"))
  diagnostics.mark(resetting ? "input.resetPost" : "input.post", session: session, sample: s, state: contact ? "contact" : "up")
 }
}
#endif
