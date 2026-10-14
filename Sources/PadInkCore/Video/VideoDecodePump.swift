import Foundation

/// A video epoch is independent of input identity: rebuilding B retires video work without
/// cancelling Pencil/Touch on A. UUID also separates attachments with the same generation.
public struct VideoDecodeContext: Equatable {
 public let attachment: InputContext, epoch: UUID
 public init(attachment: InputContext, epoch: UUID = UUID()) { self.attachment = attachment; self.epoch = epoch }
 /// A drawable already submitted by an old B may complete under the same input attachment.
 /// Invoke on the presentation thread, where `current` owns both identities.
 public static func presentedCallback(context: VideoDecodeContext?, current: @escaping () -> VideoDecodeContext?, presented: @escaping () -> Void) -> () -> Void {
  { guard let context, context == current() else { return }; presented() }
 }
}

public struct VideoDecodeQueueSnapshot: Equatable {
 public let context: VideoDecodeContext?, pendingFrames: Int, pendingBytes: Int, inFlightBytes: Int
 public let peakPendingFrames: Int, peakPendingBytes: Int, peakRetainedFrameBytes: Int
 public let droppedFrames: UInt64, recoveries: UInt64, waitingForIDR: Bool, scheduledWorkers: Int
 public let lastRecoveryReason: String?

 /// Normal configuration/IDR replacement also discards pending pictures. Those diagnostic
 /// drops are not congestion: only queue pressure, reference-chain recovery or waiting for
 /// an independent picture should ask the sender to degrade video.
 public func congested(sinceRecoveries previous: UInt64) -> Bool {
  pendingFrames >= 2 || recoveries > previous || waitingForIDR
 }
}

/// Bounded compressed-video admission, before the asynchronous media hop. Keeps a contiguous
/// reference chain; overload/age drops the whole pending chain and requests a fresh IDR. A
/// config has a separate single slot, so dropping pictures never loses the SPS/PPS they need.
/// One physical drain is scheduled, including across replacement; obsolete consumers are reset
/// on that worker after their in-flight operation retires. No client closure runs under the lock.
public final class VideoDecodePump {
 public typealias Consume = (Frame, UInt64, @escaping () -> Bool) -> Void
 private final class Consumer {
  let context: VideoDecodeContext, consume: Consume, reset: () -> Void, recovery: () -> Void
  init(_ context: VideoDecodeContext, consume: @escaping Consume, reset: @escaping () -> Void, recovery: @escaping () -> Void) {
   self.context = context; self.consume = consume; self.reset = reset; self.recovery = recovery
  }
 }
 private struct Packet { let frame: Frame, received: UInt64 }
 private let lock = NSLock(), schedule: (@escaping () -> Void) -> Void, clock: () -> UInt64
 public let frameCapacity: Int, byteCapacity: Int, maxFrameAge: UInt64
 private var desired: Consumer?, workerConsumer: Consumer? // workerConsumer is media-worker only.
 private var config: Packet?, frames: [Packet] = [], pendingBytes = 0, inFlightBytes = 0
 // A fresh IDR replaces a dependency chain even when its codec configuration is unchanged.
 private var chainRevision: UInt64 = 0, chainFirstFrame: UInt64 = 0
 private var configurationGeneration: UInt32?, lastAdmitted: UInt64 = 0, needsIDR = true, recoveryNotified = false
 private var scheduled = false, peakFrames = 0, peakBytes = 0, peakRetained = 0
 private var drops: UInt64 = 0, recoveries: UInt64 = 0
 private var lastRecoveryReason: String?

 public init(frameCapacity: Int = 2, byteCapacity: Int = 8 * 1024 * 1024,
             maxFrameAge: UInt64 = 250_000_000, clock: @escaping () -> UInt64 = { MonotonicClock.now },
             schedule: @escaping (@escaping () -> Void) -> Void) {
  self.frameCapacity = max(1, frameCapacity); self.byteCapacity = max(1, byteCapacity)
  self.maxFrameAge = maxFrameAge; self.clock = clock; self.schedule = schedule
 }
 public func activate(_ context: VideoDecodeContext, consume: @escaping Consume, reset: @escaping () -> Void, recovery: @escaping () -> Void) {
  lock.lock()
  desired = Consumer(context, consume: consume, reset: reset, recovery: recovery)
  discardLocked(); config = nil; configurationGeneration = nil; chainFirstFrame = 0; lastAdmitted = 0; needsIDR = true; recoveryNotified = false
  let start = scheduleLocked(); lock.unlock(); if start { startDrain() }
 }
 public func deactivate() {
  lock.lock(); desired = nil; discardLocked(); config = nil; configurationGeneration = nil; chainFirstFrame = 0; needsIDR = true
  let start = scheduleLocked(); lock.unlock(); if start { startDrain() }
 }
 public func isCurrent(_ context: VideoDecodeContext) -> Bool { lock.lock(); defer { lock.unlock() }; return desired?.context == context }
 public var snapshot: VideoDecodeQueueSnapshot {
  lock.lock(); defer { lock.unlock() }
  return VideoDecodeQueueSnapshot(context: desired?.context, pendingFrames: frames.count, pendingBytes: pendingBytes,
   inFlightBytes: inFlightBytes, peakPendingFrames: peakFrames, peakPendingBytes: peakBytes,
   peakRetainedFrameBytes: peakRetained, droppedFrames: drops, recoveries: recoveries,
   waitingForIDR: needsIDR, scheduledWorkers: scheduled ? 1 : 0, lastRecoveryReason: lastRecoveryReason)
 }

 /// Tiny metadata reads on the input queue; full AVCC/config validation stays on the media worker.
 @discardableResult public func push(_ frame: Frame, context: VideoDecodeContext, received: UInt64) -> Bool {
  guard frame.type == .videoConfig || frame.type == .videoFrame else { return false }
  guard frame.payload.count <= (MessageRegistry.spec(frame.type)?.maxPayload ?? 0) else { invalidate(context); return false }
  var reader = ByteReader(frame.payload)
  guard let generation = try? reader.u32(), generation > 0 else { invalidate(context); return false }
  let id: UInt64?
  if frame.type == .videoFrame { id = try? reader.u64(); guard let id, id > 0 else { invalidate(context); return false } }
  else { id = nil }
  lock.lock()
  guard let consumer = desired, consumer.context == context else { lock.unlock(); return false }
  var accepted = true, notify = false
  if frame.type == .videoConfig {
   // Wire validation caps this slot at 64 KiB. Old configurations cannot replace newer ones.
   if let old = configurationGeneration, generation < old { accepted = false }
   else {
    if generation != configurationGeneration { discardLocked(); needsIDR = true; chainFirstFrame = 0; lastAdmitted = 0 }
    configurationGeneration = generation; config = Packet(frame: frame, received: received)
   }
  } else if generation != configurationGeneration {
   drops &+= 1; accepted = false
   // A delayed old generation is harmless; it cannot discard the new independent chain.
   if configurationGeneration == nil || generation > configurationGeneration! { notify = recoverLocked("configuration") }
  } else if frame.flags.contains(.keyframe) {
   discardLocked()
   if frame.payload.count <= byteCapacity {
    needsIDR = false; recoveryNotified = false; lastAdmitted = id!; chainFirstFrame = id!
    frames.append(Packet(frame: frame, received: received)); pendingBytes = frame.payload.count
   } else { drops &+= 1; accepted = false; notify = recoverLocked("bytes") }
  } else if needsIDR {
   drops &+= 1; accepted = false; notify = recoverLocked("waitingForIDR")
  } else if id! != lastAdmitted &+ 1 || frames.count >= frameCapacity || pendingBytes + frame.payload.count > byteCapacity {
   let reason = id! != lastAdmitted &+ 1 ? "frameGap" : (frames.count >= frameCapacity ? "capacity" : "bytes")
   drops &+= 1; accepted = false; notify = recoverLocked(reason)
  } else {
   lastAdmitted = id!; frames.append(Packet(frame: frame, received: received)); pendingBytes += frame.payload.count
  }
  peakFrames = max(peakFrames, frames.count); peakBytes = max(peakBytes, pendingBytes)
  peakRetained = max(peakRetained, pendingBytes + inFlightBytes)
  let start = scheduleLocked(); lock.unlock()
  if notify { consumer.recovery() }; if start { startDrain() }; return accepted
 }
 /// Fence B/configuration replacement and late failures from a superseded IDR chain.
 public func invalidate(_ context: VideoDecodeContext, generation: UInt32? = nil, frameID: UInt64? = nil) {
  lock.lock(); guard let consumer = desired, consumer.context == context,
   generation == nil || generation == configurationGeneration,
   frameID.map({ $0 >= chainFirstFrame }) ?? true else { lock.unlock(); return }
  let notify = recoverLocked(); lock.unlock(); if notify { consumer.recovery() }
 }
 private func discardLocked() { chainRevision &+= 1; drops &+= UInt64(frames.count); frames.removeAll(keepingCapacity: true); pendingBytes = 0 }
 private func recoverLocked(_ reason: String = "invalidated") -> Bool {
  discardLocked(); needsIDR = true; lastAdmitted = 0
  guard !recoveryNotified else { return false }; recoveryNotified = true; recoveries &+= 1; lastRecoveryReason = reason; return true
 }
 private func scheduleLocked() -> Bool { guard !scheduled else { return false }; scheduled = true; return true }
 private func startDrain() { schedule { [weak self] in self?.drain() } }
 private func permit(_ context: VideoDecodeContext, received: UInt64, picture: Bool, generation: UInt32?, chain: UInt64) -> Bool {
  lock.lock(); let current = desired?.context == context && configurationGeneration == generation && (!picture || chainRevision == chain); lock.unlock()
  guard current else { return false }
  let now = clock(); return !picture || (now >= received && now - received <= maxFrameAge)
 }
 private func drain() {
  while true {
   lock.lock()
   let nextConsumer = desired
   if workerConsumer?.context != nextConsumer?.context {
    lock.unlock(); workerConsumer?.reset(); workerConsumer = nextConsumer; continue
   }
   guard let consumer = nextConsumer else { scheduled = false; lock.unlock(); return }
   let packet: Packet?, picture: Bool
   if let c = config { packet = c; config = nil; picture = false }
   else if let f = frames.first {
    let now = clock()
    if now < f.received || now - f.received > maxFrameAge {
     let notify = recoverLocked("expired"); lock.unlock(); if notify { consumer.recovery() }; continue
    }
    frames.removeFirst(); pendingBytes -= f.frame.payload.count; packet = f; picture = true
   } else { packet = nil; picture = false }
   guard let packet else { scheduled = false; lock.unlock(); return }
   inFlightBytes = picture ? packet.frame.payload.count : 0
   let generation = configurationGeneration, chain = chainRevision
   peakRetained = max(peakRetained, pendingBytes + inFlightBytes); lock.unlock()
   let context = consumer.context
   let permission = { [weak self] in self?.permit(context, received: packet.received, picture: picture, generation: generation, chain: chain) ?? false }
   if permission() { consumer.consume(packet.frame, packet.received, permission) }
   // A physical operation may complete after replacement, but cannot publish or invalidate it.
   if picture, !permission() {
    // Check and invalidate atomically: a newer IDR can arrive during an old decode.
    lock.lock()
    let current = desired?.context == context && configurationGeneration == generation && chainRevision == chain
    let notify = current ? recoverLocked("expired") : false
    lock.unlock()
    if notify { consumer.recovery() }
   }
   lock.lock(); inFlightBytes = 0; lock.unlock()
  }
 }
}
