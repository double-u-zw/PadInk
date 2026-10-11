import Foundation

/// Input freshness on the Mac (docs/ARCHITECTURE.md §4.2, fault rows 2 and 6).
///
/// Two independent checks, both on the Mac's local monotonic clock only (cross-device clocks
/// are diagnostics, never gates):
/// 1. Sample age: every input frame is stamped when it is decoded at the receive entry. Right
///    before injection its age must not exceed `maxQueueAge`; otherwise the sample is dropped and
///    the gesture is safely ended (row 2). Nothing refreshes a sample's own stamp.
/// 2. Gesture liveness: a gesture stays alive while samples or GESTURE_KEEPALIVE arrive within
///    less than `gestureTimeout` after the previous one (row 6). A gap of exactly
///    `gestureTimeout` expires it: `deadline()` is the first expired instant, so a one-shot
///    timer scheduled there always releases a stationary gesture.
///
/// Timeout is irreversible and does not depend on callback order. Every entry point — a sample,
/// a keepalive, the pre-injection verdict and the timer check — first evaluates the deadline at
/// the current processing time (`now`, made monotonic) and only then applies its message. So a
/// late message can never refresh a gesture whose deadline already passed, whether or not the
/// timer callback ran first; both orders reach the same state and report the end exactly once.
public struct InputFreshnessPolicy: Equatable {
 public var maxQueueAge: UInt64, gestureTimeout: UInt64
 /// Initial values. Phase 1 measures receive -> inject latency and sets maxQueueAge above its
 /// observed tail; both values are then recorded in PROTOCOL §4.5.
 public static let initial = InputFreshnessPolicy(maxQueueAge: 100_000_000, gestureTimeout: 1_000_000_000)
 public init(maxQueueAge: UInt64, gestureTimeout: UInt64) { self.maxQueueAge = maxQueueAge; self.gestureTimeout = gestureTimeout }
}

/// Local monotonic nanoseconds at which the frame carrying an input was decoded.
public struct ReceiveStamp: Equatable, Comparable {
 public let localTime: UInt64
 public init(localTime: UInt64) { self.localTime = localTime }
 public static func < (a: Self, b: Self) -> Bool { a.localTime < b.localTime }
}

public enum GestureEndReason: Equatable {
 /// Row 6, cancel reason code 2 (gestureTimeout).
 case timeout
 /// Row 2, cancel reason code 4 (staleSample).
 case staleSample
 /// Ended by the owner (terminal sample, explicit cancel, transport loss, preemption).
 case cancelled
}

/// Result of feeding a sample or keepalive.
public enum GestureUpdate: Equatable {
 case refreshed
 /// This call found the deadline already passed and ended the gesture. Reported exactly once
 /// across all entry points: the caller must safely release it and send INPUT_REJECTED.
 case expired
 /// The gesture had already ended; the message is dropped.
 case ignored
}

public enum InjectionVerdict: Equatable {
 case inject
 /// Row 2 transition: drop, end the gesture safely, INPUT_REJECTED(staleSample).
 case stale(age: UInt64)
 /// Row 6 transition found by this call (reported once).
 case gestureExpired
 /// The gesture already ended (stale, expired, cancelled); every later sample is dropped.
 case gestureEnded
}

public struct GestureFreshness: Equatable {
 public let gestureID: UInt64
 /// Local receive time of the latest accepted sample or keepalive.
 public private(set) var lastActivity: UInt64
 public private(set) var endReason: GestureEndReason?
 /// Largest processing time seen; decisions never move backwards in time.
 private var clock: UInt64

 public init(gestureID: UInt64, began: ReceiveStamp) {
  self.gestureID = gestureID; lastActivity = began.localTime; clock = began.localTime
 }

 public var ended: Bool { endReason != nil }
 /// First local instant at which the gesture is expired. The owner schedules its one-shot timer
 /// check exactly here; `expireIfDue(now: deadline)` returns true.
 public func deadline(policy: InputFreshnessPolicy) -> UInt64 { lastActivity &+ policy.gestureTimeout }
 /// Read-only query for UI and diagnostics. It does not end the gesture; safety decisions go
 /// through the mutating entry points, which lock the timeout.
 public func alive(now: UInt64, policy: InputFreshnessPolicy) -> Bool { !ended && max(clock, now) < deadline(policy: policy) }

 /// Timer entry point for a stationary gesture with no further messages. True exactly once,
 /// when this call ends the gesture by timeout.
 public mutating func expireIfDue(now: UInt64, policy: InputFreshnessPolicy) -> Bool {
  clock = max(clock, now)
  guard endReason == nil, clock >= deadline(policy: policy) else { return false }
  endReason = .timeout; return true
 }

 public mutating func sampleReceived(_ stamp: ReceiveStamp, now: UInt64, policy: InputFreshnessPolicy) -> GestureUpdate {
  activity(stamp, now: now, policy: policy)
 }
 /// Extends gesture liveness only. Has no access to, and no effect on, sample stamps.
 public mutating func keepaliveReceived(_ stamp: ReceiveStamp, now: UInt64, policy: InputFreshnessPolicy) -> GestureUpdate {
  activity(stamp, now: now, policy: policy)
 }

 public mutating func cancel() { if endReason == nil { endReason = .cancelled } }

 /// Call immediately before posting the event for a sample of this gesture.
 public mutating func verdict(for sample: ReceiveStamp, now: UInt64, policy: InputFreshnessPolicy) -> InjectionVerdict {
  if ended { _ = expireIfDue(now: now, policy: policy); return .gestureEnded }
  if expireIfDue(now: now, policy: policy) { return .gestureExpired }
  let age = clock >= sample.localTime ? clock - sample.localTime : 0
  guard age <= policy.maxQueueAge else { endReason = .staleSample; return .stale(age: age) }
  return .inject
 }

 private mutating func activity(_ stamp: ReceiveStamp, now: UInt64, policy: InputFreshnessPolicy) -> GestureUpdate {
  if ended { clock = max(clock, now); return .ignored }
  // Deadline first, at processing time, before this message may move it.
  if expireIfDue(now: max(now, stamp.localTime), policy: policy) { return .expired }
  lastActivity = max(lastActivity, stamp.localTime)
  return .refreshed
 }
}
