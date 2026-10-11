import Foundation

/// Mac semantic safety; classification happens only on iPad. No mouse event or app API here.
public struct TouchOwnership {
 public enum Command: Equatable { case inject(TouchEvent), release(CancelReason), reject(GestureNotice) }
 public private(set) var active: GestureFreshness?, last: TouchEvent?, geometry: PresentedGeometry?
 public var enabled = false
 public let policy: InputFreshnessPolicy
 private var ended: [UInt64] = []
 public init(policy: InputFreshnessPolicy = .initial) { self.policy = policy }
 public var deadline: UInt64? { active?.deadline(policy: policy) }
 public mutating func receive(_ event: TouchEvent, stamp: ReceiveStamp, now: UInt64, pencilActive: Bool) -> [Command] {
  if ended.contains(event.gestureID) { return [] }
  if event.phase == .began {
   // Decide admission before handing off the old contact. Invalid/duplicate began cannot
   // revoke valid execution work owned by it. Classification remains solely on iPad.
   if active?.gestureID == event.gestureID { return [] }
   guard enabled, !pencilActive else { return reject(event.gestureID, .pencilPreempted) }
   guard let geometry, geometry.ready, geometry.generation == event.geometryGeneration else { return reject(event.gestureID, .geometryMismatch) }
   guard event.sequence == 1 else { return reject(event.gestureID, .protocolViolation) }
   var candidate = GestureFreshness(gestureID: event.gestureID, began: stamp)
   switch candidate.verdict(for: stamp, now: now, policy: policy) {
   case .inject:
    let out = cancel(.protocolViolation); active = candidate; last = event
    return out + [.inject(event)]
   case .stale: return reject(event.gestureID, .staleSample)
   default: return reject(event.gestureID, .gestureTimeout)
   }
  }
  guard enabled, !pencilActive else { return cancel(.pencilPreempted) + reject(event.gestureID, .pencilPreempted) }
  guard let geometry, geometry.ready, geometry.generation == event.geometryGeneration else { return cancel(.geometryMismatch) + reject(event.gestureID, .geometryMismatch) }
  guard var current = active, current.gestureID == event.gestureID, let previous = last else { return reject(event.gestureID, .protocolViolation) }
  guard event.kind == previous.kind, event.sequence == previous.sequence &+ 1, event.sequence > previous.sequence,
        event.timestamp >= previous.timestamp, event.clickCount == previous.clickCount else { return cancel(.protocolViolation) }
  if current.sampleReceived(stamp, now: now, policy: policy) != .refreshed { active = current; return cancel(.gestureTimeout) }
  active = current; return admit(event, stamp: stamp, now: now)
 }
 private mutating func admit(_ event: TouchEvent, stamp: ReceiveStamp, now: UInt64) -> [Command] {
  guard var current = active else { return [] }; let v = current.verdict(for: stamp, now: now, policy: policy); active = current
  switch v {
  case .inject: last = event; return [.inject(event)]
  case .stale: return cancel(.staleSample)
  default: return cancel(.gestureTimeout)
  }
 }
 public mutating func delivered(_ event: TouchEvent) {
  if active?.gestureID == event.gestureID, event.phase == .ended || event.phase == .cancelled { remember(event.gestureID); active = nil; last = nil }
 }
 public mutating func cancel(_ reason: CancelReason) -> [Command] {
  guard let current = active else { return [] }; remember(current.gestureID); active = nil; last = nil
  return [.release(reason), .reject(GestureNotice(gestureID: current.gestureID, reason: reason))]
 }
 public mutating func updateGeometry(_ next: PresentedGeometry) -> [Command] {
  geometry = next; return last.map { !next.ready || $0.geometryGeneration != next.generation } == true ? cancel(.geometryMismatch) : []
 }
 public mutating func timer(now: UInt64) -> [Command] {
  guard var current = active else { return [] }; let expired = current.expireIfDue(now: now, policy: policy); active = current
  return expired ? cancel(.gestureTimeout) : []
 }
 public mutating func keepalive(_ notice: GestureKeepalive, stamp: ReceiveStamp, now: UInt64) -> [Command] {
  guard var current = active, current.gestureID == notice.gestureID else { return [] }
  let update = current.keepaliveReceived(stamp, now: now, policy: policy); active = current
  return update == .refreshed ? [] : cancel(.gestureTimeout)
 }
 private mutating func reject(_ id: UInt64, _ reason: CancelReason) -> [Command] { remember(id); return [.reject(GestureNotice(gestureID: id, reason: reason))] }
 private mutating func remember(_ id: UInt64) { if !ended.contains(id) { ended.append(id); if ended.count > 128 { ended.removeFirst() } } }
}
