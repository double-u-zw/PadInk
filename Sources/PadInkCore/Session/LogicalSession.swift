import Foundation

/// The thin logical session (ARCHITECTURE §4.1). It outlives transport attachments and holds only
/// what a reconnect needs: resume token, generation, and whether the user asked to stay offline.
/// No acknowledgements, retransmission or stroke migration: input is never replayed and video
/// restarts from a new IDR. Mac side; the iPad mirrors generation from HELLO.
/// Mac-side decision whether to look for the iPad now. Pure, so display change, permission loss and
/// restore, and sleep/wake are testable without USB (review of 71bdd94, P1 #4).
public struct DialGate: Equatable {
 public var permissionsGranted = false, sleeping = false, dialing = false
 public private(set) var lastAttempt: UInt64?
 public var interval: UInt64 = 1_000_000_000
 public init() {}
 public func shouldDial(now: UInt64, attached: Bool, session: LogicalSession) -> Bool {
  guard !attached, !dialing, !sleeping, permissionsGranted else { return false }
  switch session.state { case .paused, .needsUpdate, .attaching, .active: return false; case .idle, .reconnecting: break }
  if let last = lastAttempt, now &- last < interval { return false }
  return true
 }
 public mutating func attempted(now: UInt64) { lastAttempt = now; dialing = true }
 public mutating func finishedAttempt() { dialing = false }
 /// After wake, try immediately instead of waiting for the interval.
 public mutating func woke() { sleeping = false; lastAttempt = nil }
}

public struct LogicalSession: Equatable {
 public enum State: Equatable { case idle, attaching(UInt32), active(UInt32), reconnecting, paused, needsUpdate(VersionNegotiation) }
 public enum Action: Equatable {
  /// Owner must Input.cancelAll(transportLost) before anything else.
  case cancelInputAndReconnect
  case reconnect
  case stayOffline
 }
 public private(set) var state: State = .idle
 public private(set) var generation: UInt32 = 0
 public let resumeToken: Data
 public private(set) var reconnects = 0

 public init(resumeToken: Data) { precondition(resumeToken.count == 32); self.resumeToken = resumeToken }
 public static func newToken() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

 /// Returns the generation for the next attachment, or nil while paused / blocked on an update.
 public mutating func beginAttachment() -> UInt32? {
  switch state { case .paused, .needsUpdate, .attaching, .active: return nil; default: break }
  generation &+= 1; if generation == 0 { generation = 1 }
  state = .attaching(generation); return generation
 }
 public mutating func attachmentReady(generation g: UInt32) { if state == .attaching(g) { state = .active(g) } }

 public mutating func attachmentEnded(generation g: UInt32, _ end: AttachmentEnd) -> Action {
  guard state == .attaching(g) || state == .active(g) else { return .stayOffline }
  let wasActive = state == .active(g)
  switch end {
  case .versionMismatch(let outcome): state = .needsUpdate(outcome); return wasActive ? .cancelInputAndReconnect : .stayOffline
  case .peerError(.versionMismatch): state = .needsUpdate(.updateThisDevice); return .stayOffline
  case .peerError(.authenticationFailed), .closedLocally(.forgetDevice), .peerGoodbye(.forgetDevice), .closedLocally(.userDisconnect), .peerGoodbye(.userDisconnect): state = .paused; return wasActive ? .cancelInputAndReconnect : .stayOffline
  // Any other local close (display change, missing permission, Mac sleep, settings) is not a user
  // decision: it falls through to reconnecting; DialGate decides when dialing is possible again.
  default:
   state = .reconnecting; reconnects += 1
   return wasActive ? .cancelInputAndReconnect : .reconnect
  }
 }
 public mutating func userDisconnect() { state = .paused }
 public mutating func userResume() { if case .paused = state { state = .idle } else if case .needsUpdate = state { state = .idle } }
}
