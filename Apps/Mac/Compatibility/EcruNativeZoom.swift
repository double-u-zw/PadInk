#if os(macOS)
import AppKit
import PadInkCore

/// Ecru bridge v1: a public, unmodified-key scroll event with a private payload.
/// Axis 1/2 remain zero, so an older Ecru cannot accidentally scroll or type.
/// Axis 3 carries log(scale) in millionths; location is the moving centroid.
final class EcruNativeZoom {
 static let marker: Int64 = 0x50494E4B0001
 private var active: (context: ZoomActionContext, point: CGPoint)?
 private let validate: (ZoomTargetSnapshot, Bool) throws -> Void
 private let post: (CGEvent, pid_t) -> Void
 init(post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) },
      validate: @escaping (ZoomTargetSnapshot, Bool) throws -> Void = EcruNativeZoom.validateTarget) {
  self.post = post; self.validate = validate
 }
 private static func validateTarget(_ target: ZoomTargetSnapshot, beginning: Bool) throws {
  guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier == target.pid else { throw ZoomFailure.changedTarget }
  if beginning {
   guard let url = app.bundleURL, let bundle = Bundle(url: url),
    (bundle.object(forInfoDictionaryKey: "PadInkGestureBridgeVersion") as? NSNumber)?.intValue == 1 else { throw ZoomFailure.unavailable }
  }
  var window: CFTypeRef?
  guard AXUIElementCopyAttributeValue(target.app, kAXFocusedWindowAttribute as CFString, &window) == .success,
   let window, CFEqual(window, target.window) else { throw ZoomFailure.changedTarget }
 }

 static func event(logDelta: Double, phase: TouchPhase, point: CGPoint) throws -> CGEvent {
  guard logDelta.isFinite, abs(logDelta) <= 1, point.x.isFinite, point.y.isFinite,
   let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 3, wheel1: 0, wheel2: 0, wheel3: 0) else { throw PayloadError.value }
  event.flags = []; event.location = point
  event.setIntegerValueField(.eventSourceUserData, value: marker)
  event.setIntegerValueField(.scrollWheelEventPointDeltaAxis3, value: Int64((logDelta * 1_000_000).rounded()))
  let phases: [TouchPhase: Int64] = [.began: 1, .changed: 2, .ended: 4, .cancelled: 8]
  event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phases[phase]!)
  event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
  return event
 }

 func receive(_ event: TouchEvent, context: ZoomActionContext, bounds: CGRect) throws {
  guard let target = context.target, target.family == .ecru,
   target.revision == context.targetRevision else { cancel(); throw ZoomFailure.changedTarget }
  do { try validate(target, event.phase == .began) }
  catch { cancel(); throw error }
  let point = VideoGeometry.macPoint(normalized: CGPoint(x: Double(event.x), y: Double(event.y)), captureBounds: bounds)
  if event.phase == .began { cancel(); active = (context, point) }
  guard active?.context.actionID == context.actionID else { return }
  let output = try Self.event(logDelta: event.phase == .changed && event.kind == .magnify ? Double(event.dx) : 0, phase: event.phase, point: point)
  post(output, target.pid)
  active = event.phase == .ended || event.phase == .cancelled ? nil : (context, point)
 }
 func cancel() {
  guard let active else { return }; self.active = nil
  if let pid = active.context.target?.pid,
   let event = try? Self.event(logDelta: 0, phase: .cancelled, point: active.point) { post(event, pid) }
 }
}
#endif
