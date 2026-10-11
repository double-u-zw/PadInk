#if canImport(UIKit)
import UIKit
import MetalKit
import PadInkCore

/// Metal surface + Apple Pencil capture, ported from Baseline v0.1.0 PencilView (B-002, B-003).
/// Kept unchanged: synchronous copy of actual + coalesced UIKit samples, timestamp ordering and
/// de-duplication, stationary terminal kept, estimated-property updates logged not appended,
/// letterbox starts ignored, geometry change cancels the stroke at its last actual sample, writing
/// only after the geometry actually presented. Fingers never enter this path (Phase 1 is Pencil only).
///
/// 0.3 changes: the u32 geometry generation and its PRESENTED_GEOMETRY announcement; gesture state
/// reported to the coordinator, whose queue timer sends GESTURE_KEEPALIVE (not the main thread);
/// a Mac-side INPUT_REJECTED ends the local stroke without sending anything further.
public final class PencilView: MTKView {
 let touchCapture = TouchCapture()
 public var touchEnabled: Bool { get { touchCapture.enabled } set { touchCapture.enabled = newValue } }
 public var renderer: MetalRenderer?
 public var diagnostics: Diagnostics?
 /// Non-zero only while an attachment is ready. Changing it resets capture and geometry.
 public var session: UInt64 = 0 { didSet { if session != oldValue { touchCapture.reset(); contact = nil; captureState.reset(); geometryState = PencilGeometryState(); announced = nil; estimatedSamples.removeAll(); renderer?.invalidateInputGeometry(); reportGesture(nil) } } }
 /// Samples of one stroke, always one geometry generation; sent as one PENCIL batch.
 public var send: (([PencilSample]) -> Void)?
 public var sendGeometry: ((PresentedGeometry) -> Void)?
 /// (gestureID, last sample sequence) while a stroke is active; nil when it ends.
 public var gestureState: (((UInt64, UInt32)?) -> Void)?
 private var contact: UITouch?
 private var captureState = PencilCapture()
 private var geometryState = PencilGeometryState()
 private var estimatedSamples = [Int64: PencilSample]()
 private var callbackID: UInt64 = 0
 private var announced: PresentedGeometry?
 private struct Snapshot {
  let point: CGPoint, timestamp: UInt64, pressure: Float, altitude: Float, azimuth: Float, estimated: UInt64, expecting: UInt64, index: Int64?
  init(_ touch: UITouch, in view: UIView) {
   point = touch.preciseLocation(in: view); timestamp = UInt64(touch.timestamp * 1e9)
   pressure = Float(touch.maximumPossibleForce > 0 ? min(1, max(0, touch.force / touch.maximumPossibleForce)) : 0)
   altitude = Float(touch.altitudeAngle); azimuth = Float(touch.azimuthAngle(in: view))
   estimated = UInt64(touch.estimatedProperties.rawValue); expecting = UInt64(touch.estimatedPropertiesExpectingUpdates.rawValue); index = touch.estimationUpdateIndex?.int64Value
  }
  func sameValues(as other: Self) -> Bool { timestamp == other.timestamp && point == other.point && pressure == other.pressure && altitude == other.altitude && azimuth == other.azimuth }
 }

 /// Called on the main thread by the renderer using the geometry of its actual frame.
 public func configureTouch(send: @escaping (TouchEvent) -> Void, gesture: @escaping (((UInt64, UInt32)?) -> Void)) {
  touchCapture.bind(self); touchCapture.send = send; touchCapture.gestureState = gesture
  touchCapture.geometry = { [weak self] in guard let self, self.session != 0, let g = self.geometryState.geometry else { return nil }; return (g, self.geometryState.generation, self.geometryState.ready) }
 }
 public func willRender(_ geometry: VideoGeometry) -> UInt32 {
  let old = geometryState.generation
  if geometryState.geometry != geometry { touchCapture.cancel() }
  let cancelled = geometryState.update(geometry, orientation: window?.windowScene?.interfaceOrientation.rawValue ?? 0)
  if cancelled { cancelContact(reason: "geometryChanged") }
  if old != geometryState.generation {
   let r = geometry.rect
   diagnostics?.mark("input.geometry", session: session, state: "bounds=\(geometry.bounds); source=\(geometry.source); videoRect=\(r); orientation=\(geometryState.orientation)", geometryGeneration: geometryState.generation)
   announce()
  }
  return geometryState.generation
 }
 public func didPresent(generation: UInt32) { geometryState.presented(generation: generation); announce() }
 private func announce() {
  guard session != 0, geometryState.generation > 0, let g = geometryState.geometry else { return }
  let value = PresentedGeometry(generation: geometryState.generation, ready: geometryState.ready, orientation: UInt8(clamping: geometryState.orientation), videoWidth: UInt32(g.source.width), videoHeight: UInt32(g.source.height))
  guard value != announced else { return }
  announced = value; sendGeometry?(value)
 }
 private func refreshGeometry() { if var g = renderer?.geometry { g.bounds = bounds; _ = willRender(g) } }

 public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
  refreshGeometry()
  if touches.contains(where: { $0.type == .pencil }) { touchCapture.pencil(true) }
  touchCapture.update(touches, phase: .began, event: event)
  guard session != 0, contact == nil, let touch = touches.first(where: { $0.type == .pencil }), geometryState.begin(touch.preciseLocation(in: self)) != nil else { return }
  contact = touch; capture(touch, event: event, phase: .begin)
 }
 public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { refreshGeometry(); touchCapture.update(touches, phase: .moved, event: event); guard let touch = contact, touches.contains(touch) else { return }; capture(touch, event: event, phase: .move) }
 public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { refreshGeometry(); touchCapture.update(touches, phase: .ended, event: event); if touches.contains(where: { $0.type == .pencil }) { touchCapture.pencil(false) }; guard let touch = contact, touches.contains(touch) else { return }; capture(touch, event: event, phase: .end); contact = nil; geometryState.end() }
 public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchCapture.update(touches, phase: .cancelled, event: event); if touches.contains(where: { $0.type == .pencil }) { touchCapture.pencil(false) }; guard let touch = contact, touches.contains(touch) else { return }; capture(touch, event: event, phase: .cancel); contact = nil; geometryState.end(); diagnostics?.mark("input.cancelReason", session: session, state: "UIKit cancelled", geometryGeneration: geometryState.generation) }

 /// Local cancellation at the last actual sample (geometry change, app background).
 public func cancelContact(reason: String) {
  touchCapture.cancel(); touchCapture.pencil(false)
  if let sample = captureState.cancel() { diagnostics?.mark("input.cancelReason", session: session, sample: sample, state: reason); send?([sample]) }
  contact = nil; geometryState.end(); reportGesture(nil)
 }
 /// The Mac ended this stroke (INPUT_REJECTED). Stop capturing it; nothing more is sent.
 public func rejected(gestureID: UInt64, reason: CancelReason) {
  if gestureID & (1 << 63) != 0 { touchCapture.rejected(gestureID); return }
  guard let active = activeStroke, active == gestureID else { return }
  diagnostics?.mark("input.rejected", session: session, item: gestureID, state: String(describing: reason))
  captureState.reset(); contact = nil; geometryState.end(); reportGesture(nil)
 }
 private var activeStroke: UInt64?

 private func capture(_ touch: UITouch, event: UIEvent?, phase: PencilPhase) {
  guard session != 0 else { return }
  let entered = MonotonicClock.now
  defer {
   let exited = MonotonicClock.now
   diagnostics?.performance.record(PerformanceEvent("input.uiCallback", time: exited, generation: session, item: callbackID, start: entered, end: exited, code: String(describing: phase)))
  }
  // Copy all UIKit values synchronously; UITouch never leaves this callback.
  var actual = (event?.coalescedTouches(for: touch) ?? [touch]).map { Snapshot($0, in: self) }
  let current = Snapshot(touch, in: self)
  if !actual.contains(where: { $0.sameValues(as: current) }) { actual.append(current) }
  actual = actual.enumerated().sorted { $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp }.map(\.element)
  callbackID += 1
  for (index, raw) in actual.enumerated() { diagnostics?.mark("input.callbackRaw", session: session, item: callbackID, sequence: UInt64(index + 1), sourceTime: raw.timestamp, state: "UIKit actual callback \(phase)", value: Double(raw.pressure), viewX: raw.point.x, viewY: raw.point.y, estimatedProperties: raw.estimated, expectingUpdates: raw.expecting, estimationIndex: raw.index, geometryGeneration: geometryState.generation) }
  let mapped = actual.compactMap { s -> (Snapshot, ActualPoint)? in
   guard let p = geometryState.map(s.point) else { return nil }
   return (s, ActualPoint(timestamp: s.timestamp, x: Float(p.x), y: Float(p.y), pressure: s.pressure, altitude: s.altitude, azimuth: s.azimuth, flags: s.estimated == 0 ? 0 : 1))
  }
  var samples = captureState.capture(mapped.map(\.1), callback: phase, geometryGeneration: geometryState.generation) { [weak self] sample, index in
   guard let self else { return }; let raw = mapped[index].0
   self.diagnostics?.mark("input.raw", session: self.session, sample: sample, viewX: raw.point.x, viewY: raw.point.y, estimatedProperties: raw.estimated, expectingUpdates: raw.expecting, estimationIndex: raw.index)
   if raw.expecting != 0, let key = raw.index { if self.estimatedSamples.count >= 512 { self.estimatedSamples.removeAll() }; self.estimatedSamples[key] = sample }
  }
  guard !samples.isEmpty, let last = samples.last else { return }
  let terminal = phase == .end || phase == .cancel
  reportGesture(terminal ? nil : (last.stroke, UInt32(last.sequence)))
  // A stroke's first batch carries only the begin sample (Baseline), then <= 256 samples per batch.
  if samples.first?.phase == PencilPhase.begin.rawValue { send?([samples.removeFirst()]) }
  while samples.count > PencilBatch.maxSamples { send?(Array(samples.prefix(PencilBatch.maxSamples))); samples.removeFirst(PencilBatch.maxSamples) }
  if !samples.isEmpty { send?(samples) }
 }
 private func reportGesture(_ state: (UInt64, UInt32)?) { activeStroke = state?.0; gestureState?(state) }

 public override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
  for touch in touches {
   let raw = Snapshot(touch, in: self)
   guard let index = raw.index, let original = estimatedSamples[index] else { continue }
   diagnostics?.mark("input.estimatedUpdate", session: session, sample: original, state: "historical update; not appended as a movement", value: Double(raw.pressure), viewX: raw.point.x, viewY: raw.point.y, estimatedProperties: raw.estimated, expectingUpdates: raw.expecting, estimationIndex: index)
   if raw.expecting == 0 { estimatedSamples.removeValue(forKey: index) }
  }
 }
 public override func layoutSubviews() { super.layoutSubviews(); renderer?.geometry.bounds = bounds; refreshGeometry() }
}
#endif
