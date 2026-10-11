#if canImport(UIKit)
import UIKit
import PadInkCore

/// Main-thread UIKit adapter; the classifier itself is platform independent and replay tested.
final class TouchCapture: NSObject {
 weak var view: UIView?
 var geometry: () -> (VideoGeometry, UInt32, Bool)? = { nil }
 var send: (TouchEvent) -> Void = { _ in }
 var gestureState: (((UInt64, UInt32)?) -> Void)?
 private var fsm = GestureFSM(), touches: [ObjectIdentifier: (UInt64, CGPoint)] = [:], nextID: UInt64 = 0
 private var timer: Timer?, hover: UIHoverGestureRecognizer?
 var enabled: Bool { get { fsm.touchEnabled } set { if !newValue { cancel() }; fsm.touchEnabled = newValue } }
 func bind(_ view: UIView) {
  self.view = view; view.isMultipleTouchEnabled = true
  let h = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))); h.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]; h.cancelsTouchesInView = false
  view.addGestureRecognizer(h); hover = h
 }
 func update(_ changed: Set<UITouch>, phase: UITouch.Phase, event: UIEvent?) {
  guard let view else { return }
  let now = MonotonicClock.now
  // Refresh all fingers from this UIEvent rather than mixing callback times.
  for touch in event?.touches(for: view) ?? changed where touch.type == .direct {
   let key = ObjectIdentifier(touch)
   if touch.phase == .ended || touch.phase == .cancelled { touches.removeValue(forKey: key) }
   else {
    if touches[key] == nil { nextID += 1 }
    touches[key] = (touches[key]?.0 ?? nextID, touch.location(in: view))
   }
  }
  let points = touches.values.map { FingerPoint($0.0, $0.1) }
  if phase == .cancelled { emit(fsm.cancel(now: now)) }
  emit(fsm.update(points, now: now)); arm()
 }
 func pencil(_ present: Bool) { emit(fsm.setPencil(present, now: MonotonicClock.now)); arm() }
 func cancel() { emit(fsm.cancel(now: MonotonicClock.now)); arm() }
 func reset() { timer?.invalidate(); timer = nil; touches.removeAll(); fsm.reset(); gestureState?(nil) }
 func rejected(_ id: UInt64) {
  guard fsm.active?.0 == id else { return }; _ = fsm.cancel(now: MonotonicClock.now); gestureState?(nil); arm()
 }
 @objc private func hovered(_ h: UIHoverGestureRecognizer) {
  emit(fsm.setPencil(h.state == .began || h.state == .changed, hover: true, now: MonotonicClock.now)); arm()
 }
 private func emit(_ actions: [TouchAction]) {
  for action in actions {
   guard let (g, generation, ready) = geometry(), ready,
         let p = g.normalized(action.point, clamp: action.phase != .began) else { _ = fsm.cancel(now: MonotonicClock.now); continue }
   let delta = action.kind == .scroll ? g.normalizedDelta(action.delta) : action.delta
   let e = TouchEvent(gestureID: action.id, sequence: action.sequence, timestamp: action.timestamp, geometryGeneration: generation,
     kind: action.kind, phase: action.phase, clickCount: action.clicks, x: Float(p.x), y: Float(p.y), dx: Float(max(-1, min(1, delta.x))), dy: Float(max(-1, min(1, delta.y))))
   send(e)
  }
  gestureState?(fsm.active)
 }
 private func arm() {
  timer?.invalidate(); timer = nil
  guard let due = fsm.deadline else { return }
  let now = MonotonicClock.now
  let t = Timer(timeInterval: max(0.001, Double(due > now ? due - now : 0) / 1e9), repeats: false) { [weak self] _ in guard let self else { return }; self.emit(self.fsm.timer(now: MonotonicClock.now)); self.arm() }
  RunLoop.main.add(t, forMode: .common); timer = t
 }
}
#endif
