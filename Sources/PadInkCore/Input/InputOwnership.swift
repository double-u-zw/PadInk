import Foundation

/// Mac-side gatekeeper for Pencil input (ARCHITECTURE §6.2; fault rows 2, 4, 5, 6, 7).
/// Pure state on the input queue. It decides; the PencilInjectionBackend executes. The backend
/// keeps Baseline's transactional InputSession and event timing, so this type never builds events.
///
/// Rules:
/// - A stroke may begin only on the latest PRESENTED_GEOMETRY generation, and only when it is
///   ready (row 4). Otherwise the stroke is rejected and its later batches are dropped.
/// - Liveness and sample age use GestureFreshness (rows 2 and 6): every entry point locks the
///   timeout first; a stale batch or expired gesture is released and rejected.
/// - Releasing always means "post up + proximity-out at the last injected sample" (backend reset).
/// - Every decision about a gesture ends in exactly one INPUT_REJECTED at most.
public struct InputOwnership {
 public enum Command: Equatable {
  /// Inject this batch now (verdict already checked at `now`). The owner must report the outcome:
  /// `injected(_:)` on success, `backendRejected(gestureID:)` on failure. A terminal batch completes
  /// the gesture only in `injected(_:)`, so a rejected terminal still leaves an active gesture to release.
  case inject(PencilBatch)
  /// Post the safe release for the active stroke.
  case release(CancelReason)
  /// Tell the iPad the gesture ended on the Mac (INPUT_REJECTED).
  case reject(GestureNotice)
 }

 public let policy: InputFreshnessPolicy
 public private(set) var geometry: PresentedGeometry?
 public private(set) var active: GestureFreshness?
 /// Gestures that ended on the Mac; their late batches are dropped silently. Bounded.
 private var ended: [UInt64] = []
 public private(set) var cancelCounts: [CancelReason: Int] = [:]

 public init(policy: InputFreshnessPolicy = .initial) { self.policy = policy }

 /// Absolute local time for the owner's one-shot timer, if a stroke is active.
 public var nextDeadline: UInt64? { active.map { $0.deadline(policy: policy) } }

 public mutating func presentedGeometry(_ g: PresentedGeometry) -> [Command] {
  geometry = g
  guard let a = active, let batchGeneration = activeGeneration, batchGeneration != g.generation || !g.ready else { return [] }
  return end(a.gestureID, .geometryMismatch, notify: true)
 }

 public mutating func pencil(_ batch: PencilBatch, stamp: ReceiveStamp, now: UInt64) -> [Command] {
  let id = batch.gestureID
  if ended.contains(id) { return [] }
  if batch.batchFlags & 1 != 0 {
   var out = [Command]()
   if let a = active { out += end(a.gestureID, .protocolViolation, notify: true) }
   guard let g = geometry, g.ready, g.generation == batch.geometryGeneration else { return out + reject(id, .geometryMismatch) }
   active = GestureFreshness(gestureID: id, began: stamp); activeGeneration = batch.geometryGeneration
   return out + admit(batch, stamp: stamp, now: now)
  }
  guard var a = active, a.gestureID == id else { return reject(id, .sessionReplaced) }
  switch a.sampleReceived(stamp, now: now, policy: policy) {
  case .expired: active = a; return end(id, .gestureTimeout, notify: true)
  case .ignored: active = a; return end(id, a.endReason.map(Self.reason) ?? .gestureTimeout, notify: true)
  case .refreshed: active = a; return admit(batch, stamp: stamp, now: now)
  }
 }

 public mutating func keepalive(_ k: GestureKeepalive, stamp: ReceiveStamp, now: UInt64) -> [Command] {
  guard var a = active, a.gestureID == k.gestureID else { return [] }
  let update = a.keepaliveReceived(stamp, now: now, policy: policy); active = a
  return update == .refreshed ? [] : end(a.gestureID, .gestureTimeout, notify: true)
 }

 /// iPad cancelled its own gesture (INPUT_CANCEL): release, no reply.
 public mutating func cancelFromPeer(_ n: GestureNotice) -> [Command] {
  guard let a = active, a.gestureID == n.gestureID else { return [] }
  return end(a.gestureID, n.reason, notify: false)
 }

 /// One-shot timer at `nextDeadline`.
 public mutating func timer(now: UInt64) -> [Command] {
  guard var a = active else { return [] }
  let expired = a.expireIfDue(now: now, policy: policy); active = a
  return expired ? end(a.gestureID, .gestureTimeout, notify: true) : []
 }

 /// Transport lost (row 7), target app changed (row 5), app background, settings change.
 /// No reply is possible or needed for transportLost.
 public mutating func cancelAll(_ reason: CancelReason) -> [Command] {
  // Gesture IDs are only unique within one attachment: the iPad restarts them at 1 after a relaunch.
  // So the ended-gesture record and the geometry are session-scoped.
  defer { if reason == .transportLost || reason == .sessionReplaced { geometry = nil; ended.removeAll() } }
  guard let a = active else { return [] }
  return end(a.gestureID, reason, notify: reason != .transportLost && reason != .sessionReplaced)
 }

 /// The backend posted an admitted batch. Completes the gesture when the batch was terminal.
 public mutating func injected(_ batch: PencilBatch) {
  guard active?.gestureID == batch.gestureID, batch.batchFlags & 2 != 0 else { return }
  finished(batch.gestureID)
 }

 /// The backend rejected an admitted batch (Baseline InputSession sequence check).
 public mutating func backendRejected(gestureID: UInt64) -> [Command] {
  guard let a = active, a.gestureID == gestureID else { return [] }
  return end(gestureID, .protocolViolation, notify: true)
 }

 // MARK: Internals

 private var activeGeneration: UInt32?

 private mutating func admit(_ batch: PencilBatch, stamp: ReceiveStamp, now: UInt64) -> [Command] {
  guard var a = active else { return [] }
  let verdict = a.verdict(for: stamp, now: now, policy: policy); active = a
  switch verdict {
  case .inject:
   return [.inject(batch)]
  case .stale: return end(batch.gestureID, .staleSample, notify: true)
  case .gestureExpired: return end(batch.gestureID, .gestureTimeout, notify: true)
  case .gestureEnded: return end(batch.gestureID, a.endReason.map(Self.reason) ?? .gestureTimeout, notify: true)
  }
 }

 private mutating func finished(_ id: UInt64) { active = nil; activeGeneration = nil; remember(id) }

 private mutating func end(_ id: UInt64, _ reason: CancelReason, notify: Bool) -> [Command] {
  let wasActive = active?.gestureID == id
  finished(id)
  cancelCounts[reason, default: 0] += 1
  var out = [Command]()
  if wasActive { out.append(.release(reason)) }
  if notify { out.append(.reject(GestureNotice(gestureID: id, reason: reason))) }
  return out
 }

 private mutating func reject(_ id: UInt64, _ reason: CancelReason) -> [Command] {
  remember(id); cancelCounts[reason, default: 0] += 1
  return [.reject(GestureNotice(gestureID: id, reason: reason))]
 }

 private mutating func remember(_ id: UInt64) { if !ended.contains(id) { ended.append(id); if ended.count > 64 { ended.removeFirst() } } }

 private static func reason(_ r: GestureEndReason) -> CancelReason {
  switch r { case .timeout: return .gestureTimeout; case .staleSample: return .staleSample; case .cancelled: return .protocolViolation }
 }
}
