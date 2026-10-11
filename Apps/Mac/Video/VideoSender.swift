#if os(macOS)
import Foundation
import PadInkCore

/// Mac video send queue on the attachment queue. Baseline's GOP-bounded queue with one frame in
/// flight, without Baseline's "send older than 250 ms closes the session" (fault row 1).
/// Congestion ladder in Phase 1: skip before encode (`isBacklogged`) -> GOP drop + IDR (last rung).
/// Bitrate / resolution / FPS steps are Phase 2.
public final class VideoSender {
 public typealias Send = (MessageType, Data, FrameFlags, @escaping (Error?) -> Void) -> Bool
 public var send: Send = { _, _, _, _ in false }
 public var requestKeyframe: () -> Void = {}
 public var onBacklogCleared: () -> Void = {}
 private var gop = GOPQueue(capacity: 2), configs = [UInt64: VideoConfig](), sending = false, epoch: UInt64 = 0
 private let diagnostics: Diagnostics, lock = NSLock()
 private var backlogged = false
 private var slowWrite = false, writeStarted: UInt64 = 0
 /// Sampling a momentary empty queue misses slow writes. Retain interval pressure until tick.
 public func takeCongestion(now: UInt64 = MonotonicClock.now) -> Bool {
  let busyTooLong = writeStarted > 0 && now >= writeStarted && now - writeStarted > 50_000_000
  let value = slowWrite || busyTooLong || isBacklogged; slowWrite = false; return value
 }
 public init(diagnostics: Diagnostics) { self.diagnostics = diagnostics }

 /// Thread-safe: read by the encoder before each encode.
 public var isBacklogged: Bool { lock.lock(); defer { lock.unlock() }; return backlogged }
 public var queuedFrames: Int { gop.frames.count }

 public func push(_ config: VideoConfig?, _ frame: VideoFrame) {
  if let config { configs.removeAll(); configs[frame.id] = config }
  if !gop.push(frame) { configs.removeAll(); diagnostics.mark("video.gopReset", item: frame.id); requestKeyframe() }
  flush()
 }

 /// Forget everything queued (attachment ended or B rebuilt); the next frame must be a new IDR.
 public func reset() { epoch &+= 1; gop.reset(); configs.removeAll(); sending = false; writeStarted = 0; slowWrite = false; setBacklog(false) }

 private func flush() {
  guard !sending, let frame = gop.pop() else { setBacklog(sending && !gop.frames.isEmpty); return }
  sending = true; let token = epoch
  if let c = configs.removeValue(forKey: frame.id) { _ = send(.videoConfig, c.encode(), [.critical], { _ in }) }
  diagnostics.mark("video.send", item: frame.id, sourceTime: frame.captureTime, value: Double(frame.avcc.count))
  let started = MonotonicClock.now; writeStarted = started
  let payload = frame.encode(), ended = MonotonicClock.now
  diagnostics.performance.record(PerformanceEvent("video.payload", time: ended, item: frame.id, start: started, end: ended, depth: gop.frames.count, bytes: payload.count))
  let queued = send(.videoFrame, payload, frame.key ? [.critical, .keyframe] : [.critical]) { [weak self] _ in
   guard let self, self.epoch == token else { return }
   let now = MonotonicClock.now
   if now >= started && now - started > 50_000_000 { self.slowWrite = true }
   self.writeStarted = 0; self.sending = false; self.flush()
  }
  if !queued { writeStarted = 0; sending = false; gop.reset(); configs.removeAll() }
  setBacklog(sending && !gop.frames.isEmpty)
 }

 private func setBacklog(_ value: Bool) {
  lock.lock(); let was = backlogged; backlogged = value; lock.unlock()
  if was && !value { onBacklogCleared() }
 }
}
#endif
