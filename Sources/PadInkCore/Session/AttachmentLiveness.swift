import Foundation

/// Classifies one transport attachment (docs/ARCHITECTURE.md §4.2, fault rows 1, 7, 7b).
///
/// Connection A (control + input) carries only small messages, so silence on it means the
/// link is dead. Connection B (video) shares one ordered byte stream with large frames: a
/// heartbeat queued behind them can be late for seconds while the link is fine. B is
/// therefore never judged by heartbeat latency. B silence or a stalled send queue is
/// congestion first; only a transport error or a long stall rebuilds B, and even then
/// input on A is untouched. Only A decides attachment death, the only verdict that cancels input.
public struct LivenessPolicy: Equatable {
 /// A: no bytes received for this long -> attachment dead (heartbeats every 1 s keep A busy).
 public var controlSilenceLimit: UInt64
 /// B: video send queue above this -> congested (degrade, never disconnect).
 public var congestedQueueBytes: Int
 /// B: queued bytes not draining for this long -> congested.
 public var congestionDrainDelay: UInt64
 /// B: no send progress with a non-empty queue, or nothing received from the iPad, for this
 /// long -> rebuild the video connection only.
 public var videoStallLimit: UInt64
 /// Initial values; Phase 2 replaces them with measured ones and records them in PROTOCOL §4.2.
 public static let initial = LivenessPolicy(controlSilenceLimit: 3_000_000_000, congestedQueueBytes: 1 << 20,
                                            congestionDrainDelay: 250_000_000, videoStallLimit: 10_000_000_000)
 public init(controlSilenceLimit: UInt64, congestedQueueBytes: Int, congestionDrainDelay: UInt64, videoStallLimit: UInt64) {
  self.controlSilenceLimit = controlSilenceLimit; self.congestedQueueBytes = congestedQueueBytes
  self.congestionDrainDelay = congestionDrainDelay; self.videoStallLimit = videoStallLimit
 }
}

public enum VideoRebuildReason: Equatable { case connectionFailed, sendStalled, receiveSilent }
public enum AttachmentDeathReason: Equatable { case controlFailed, controlSilent }

public enum AttachmentHealth: Equatable {
 case healthy
 /// Degrade video (skip before encode, lower bitrate). Input continues.
 case videoCongested
 /// Close and reopen B within the same attachment; new IDR. Input continues, no cancel.
 case rebuildVideo(VideoRebuildReason)
 /// The only verdict that cancels input (fault row 7): cancelAll(transportLost) -> Reconnecting.
 case attachmentDead(AttachmentDeathReason)
 public var cancelsInput: Bool { if case .attachmentDead = self { return true }; return false }
}

public struct AttachmentLiveness {
 public let policy: LivenessPolicy
 private var lastControlReceive: UInt64, lastVideoReceive: UInt64, lastVideoDrain: UInt64
 private var videoQueued = 0, controlFailed = false, videoFailed = false

 public init(now: UInt64, policy: LivenessPolicy = .initial) {
  self.policy = policy; lastControlReceive = now; lastVideoReceive = now; lastVideoDrain = now
 }

 /// Any bytes received on a connection (heartbeat, ack, input, feedback, video).
 public mutating func received(on connection: ConnectionKind, now: UInt64) {
  switch connection { case .controlInput: lastControlReceive = max(lastControlReceive, now); case .video: lastVideoReceive = max(lastVideoReceive, now) }
 }
 /// Transport report for B after a send completion or enqueue: bytes still queued, and whether
 /// any bytes left the queue since the last report.
 public mutating func videoSendQueue(queuedBytes: Int, drained: Bool, now: UInt64) {
  if drained || videoQueued == 0 { lastVideoDrain = max(lastVideoDrain, now) }
  videoQueued = max(0, queuedBytes)
  if videoQueued == 0 { lastVideoDrain = max(lastVideoDrain, now) }
 }
 public mutating func connectionFailed(_ connection: ConnectionKind) {
  switch connection { case .controlInput: controlFailed = true; case .video: videoFailed = true }
 }
 /// B was reopened inside the same attachment.
 public mutating func videoRebuilt(now: UInt64) {
  videoFailed = false; videoQueued = 0; lastVideoReceive = now; lastVideoDrain = now
 }

 public func evaluate(now: UInt64) -> AttachmentHealth {
  if controlFailed { return .attachmentDead(.controlFailed) }
  if age(lastControlReceive, now) > policy.controlSilenceLimit { return .attachmentDead(.controlSilent) }
  if videoFailed { return .rebuildVideo(.connectionFailed) }
  if videoQueued > 0, age(lastVideoDrain, now) > policy.videoStallLimit { return .rebuildVideo(.sendStalled) }
  if age(lastVideoReceive, now) > policy.videoStallLimit { return .rebuildVideo(.receiveSilent) }
  if videoQueued > policy.congestedQueueBytes || (videoQueued > 0 && age(lastVideoDrain, now) > policy.congestionDrainDelay) { return .videoCongested }
  return .healthy
 }
 private func age(_ t: UInt64, _ now: UInt64) -> UInt64 { now >= t ? now - t : 0 }
}
