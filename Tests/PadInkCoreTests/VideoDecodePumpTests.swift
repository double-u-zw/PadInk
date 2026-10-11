import XCTest
@testable import PadInkCore

private final class VideoPumpScheduler {
 var tasks: [() -> Void] = [], scheduled = 0
 func enqueue(_ task: @escaping () -> Void) { tasks.append(task); scheduled += 1 }
 func run() { while !tasks.isEmpty { tasks.removeFirst()() } }
}
private final class VideoConsumerProbe { var reset = 0 }

final class VideoDecodePumpTests: XCTestCase {
 private func context(_ identity: UUID = UUID(), epoch: UUID = UUID()) -> VideoDecodeContext {
  VideoDecodeContext(attachment: InputContext(attachmentID: identity, generation: 1), epoch: epoch)
 }
 private func config(g: UInt32 = 1) -> Frame {
  Frame(type: .videoConfig, generation: 1, sequence: 1, timestamp: 1,
        payload: VideoConfig(generation: g, width: 640, height: 360, sps: Data([1]), pps: Data([2])).encode())
 }
 private func frame(_ id: UInt64, key: Bool = false, bytes: Int = 128 * 1024, g: UInt32 = 1) -> Frame {
  let video = VideoFrame(generation: g, id: id, captureTime: 1, key: key, avcc: Data(repeating: 1, count: bytes))
  return Frame(type: .videoFrame, flags: key ? [.critical, .keyframe] : [.critical], generation: 1, sequence: id + 1, timestamp: 1, payload: video.encode())
 }
 func testStalledWorkerBoundsCompressedFramesAndRecoversWithConfigAndIDR() {
  let scheduler = VideoPumpScheduler(), c = context(); var recovery = 0, consumed: [Frame] = []
  let pump = VideoDecodePump(clock: { 1 }, schedule: scheduler.enqueue)
  pump.activate(c, consume: { f, _, permit in if permit() { consumed.append(f) } }, reset: {}, recovery: { recovery += 1 })
  pump.push(config(), context: c, received: 1)
  // Same stalled media queue as the previous per-frame async path. That path retains all 120
  // payloads (15 MiB); this assertion fails without admission before the queue hop.
  for n in 1...120 { pump.push(frame(UInt64(n), key: n == 1), context: c, received: 1) }
  XCTAssertEqual(scheduler.tasks.count, 1); XCTAssertEqual(scheduler.scheduled, 1)
  XCTAssertEqual(pump.snapshot.peakPendingFrames, 2)
  XCTAssertLessThanOrEqual(pump.snapshot.peakPendingBytes, pump.byteCapacity)
  XCTAssertEqual(pump.snapshot.pendingFrames, 0); XCTAssertTrue(pump.snapshot.waitingForIDR)
  XCTAssertEqual(recovery, 1, "waiting P frames must not create a recovery-request storm")
  XCTAssertEqual(pump.snapshot.lastRecoveryReason, "capacity", "later waiting frames must not hide the original trigger")
  pump.push(frame(121, key: true), context: c, received: 1)
  pump.push(frame(122), context: c, received: 1); scheduler.run()
  XCTAssertEqual(consumed.map(\.type), [.videoConfig, .videoFrame, .videoFrame])
  var gate = DecodeGate(); gate.configure(1)
  for f in consumed.dropFirst() {
   var r = ByteReader(f.payload); let g = try! r.u32(), id = try! r.u64()
   XCTAssertTrue(gate.accept(VideoFrame(generation: g, id: id, captureTime: 1, key: f.flags.contains(.keyframe), avcc: Data([1]))))
  }
  XCTAssertEqual(pump.snapshot.pendingFrames, 0); XCTAssertEqual(pump.snapshot.scheduledWorkers, 0)
 }
 func testByteLimitDropsEntireChainAndKeepsOnlyIndependentRecovery() {
  let scheduler = VideoPumpScheduler(), c = context(); var ids: [UInt64] = [], requests = 0
  let pump = VideoDecodePump(frameCapacity: 20, byteCapacity: 100, clock: { 1 }, schedule: scheduler.enqueue)
  pump.activate(c, consume: { f, _, _ in if f.type == .videoFrame { var r = ByteReader(f.payload); _ = try! r.u32(); ids.append(try! r.u64()) } }, reset: {}, recovery: { requests += 1 })
  pump.push(config(), context: c, received: 1)
  XCTAssertTrue(pump.push(frame(1, key: true, bytes: 30), context: c, received: 1))
  XCTAssertTrue(pump.push(frame(2, bytes: 30), context: c, received: 1))
  XCTAssertFalse(pump.push(frame(3, bytes: 1), context: c, received: 1))
  XCTAssertFalse(pump.push(frame(4, bytes: 1), context: c, received: 1))
  XCTAssertEqual(pump.snapshot.lastRecoveryReason, "bytes")
  XCTAssertTrue(pump.push(frame(5, key: true, bytes: 10), context: c, received: 1)); scheduler.run()
  XCTAssertEqual(ids, [5]); XCTAssertEqual(requests, 1); XCTAssertEqual(pump.snapshot.peakPendingBytes, 100)
 }
 func testExpiredPendingChainDoesNotReplayAfterStall() {
  let scheduler = VideoPumpScheduler(), c = context(); var now: UInt64 = 1, ids: [UInt64] = [], requests = 0
  let pump = VideoDecodePump(maxFrameAge: 250, clock: { now }, schedule: scheduler.enqueue)
  pump.activate(c, consume: { f, _, _ in if f.type == .videoFrame { var r = ByteReader(f.payload); _ = try! r.u32(); ids.append(try! r.u64()) } }, reset: {}, recovery: { requests += 1 })
  pump.push(config(), context: c, received: now); pump.push(frame(1, key: true), context: c, received: now)
  now = 300; scheduler.run()
  XCTAssertTrue(ids.isEmpty); XCTAssertEqual(requests, 1); XCTAssertTrue(pump.snapshot.waitingForIDR)
  XCTAssertEqual(pump.snapshot.lastRecoveryReason, "expired")
  pump.push(frame(2, key: true), context: c, received: now); scheduler.run()
  XCTAssertEqual(ids, [2]); XCTAssertFalse(pump.snapshot.waitingForIDR)
 }
 func testOldInFlightPermitAndFailureCannotPublishOrInvalidateReplacement() {
  let scheduler = VideoPumpScheduler(), identity = UUID(), old = context(identity), fresh = context(identity)
  let pump = VideoDecodePump(clock: { 1 }, schedule: scheduler.enqueue)
  var oldPermit: (() -> Bool)?, oldResets = 0, newFrames = 0, oldRecoveries = 0, newRecoveries = 0
  pump.activate(old, consume: { f, _, permit in
   guard f.type == .videoFrame else { return }; oldPermit = permit
   pump.activate(fresh, consume: { f, _, p in if f.type == .videoFrame && p() { newFrames += 1 } }, reset: {}, recovery: { newRecoveries += 1 })
   pump.push(self.config(), context: fresh, received: 1); pump.push(self.frame(10, key: true), context: fresh, received: 1)
   pump.invalidate(old)
   XCTAssertFalse(permit())
  }, reset: { oldResets += 1 }, recovery: { oldRecoveries += 1 })
  pump.push(config(), context: old, received: 1); pump.push(frame(1, key: true), context: old, received: 1); scheduler.run()
  XCTAssertFalse(oldPermit!()); XCTAssertEqual(oldResets, 1); XCTAssertEqual(newFrames, 1)
  XCTAssertEqual(oldRecoveries, 0); XCTAssertEqual(newRecoveries, 0); XCTAssertEqual(scheduler.scheduled, 1)
  XCTAssertFalse(pump.push(frame(2), context: old, received: 1)); XCTAssertEqual(pump.snapshot.context, fresh)
 }
 func testRepeatedReplacementCoalescesConsumersAndReleasesRetiredInstances() {
  let scheduler = VideoPumpScheduler(); let pump = VideoDecodePump(clock: { 1 }, schedule: scheduler.enqueue)
  var references: [() -> Bool] = []
  for _ in 0..<1000 {
   let probe = VideoConsumerProbe(), c = context()
   references.append { [weak probe] in probe != nil }
   pump.activate(c, consume: { [probe] _, _, _ in _ = probe.reset }, reset: { [probe] in probe.reset += 1 }, recovery: {})
   pump.push(config(), context: c, received: 1); pump.push(frame(1, key: true, bytes: 64), context: c, received: 1)
   XCTAssertLessThanOrEqual(pump.snapshot.pendingFrames, 2)
  }
  XCTAssertEqual(references.filter { $0() }.count, 1); XCTAssertEqual(scheduler.tasks.count, 1)
  scheduler.run(); pump.deactivate(); scheduler.run()
  XCTAssertEqual(references.filter { $0() }.count, 0); XCTAssertEqual(pump.snapshot.scheduledWorkers, 0)
 }
 func testOldDrawableCompletionIsFencedAcrossBOnlyRebuild() {
  let identity = UUID(), old = context(identity), fresh = context(identity)
  var current: VideoDecodeContext? = old, presentations = 0
  let oldCompletion = VideoDecodeContext.presentedCallback(context: old, current: { current }, presented: { presentations += 1 })
  oldCompletion(); XCTAssertEqual(presentations, 1)
  current = fresh; oldCompletion(); XCTAssertEqual(presentations, 1)
  let freshCompletion = VideoDecodeContext.presentedCallback(context: fresh, current: { current }, presented: { presentations += 1 })
  freshCompletion(); XCTAssertEqual(presentations, 2)
  current = nil; freshCompletion(); XCTAssertEqual(presentations, 2)
 }
 func testConfigurationReplacementAndGappedPFramesNeedFreshIDR() {
  let scheduler = VideoPumpScheduler(), c = context(); var consumed: [Frame] = [], requests = 0
  let pump = VideoDecodePump(clock: { 1 }, schedule: scheduler.enqueue)
  pump.activate(c, consume: { f, _, _ in consumed.append(f) }, reset: {}, recovery: { requests += 1 })
  pump.push(config(), context: c, received: 1); pump.push(frame(1, key: true), context: c, received: 1)
  pump.push(config(g: 2), context: c, received: 1)
  pump.push(frame(10, key: true, g: 2), context: c, received: 1)
  XCTAssertFalse(pump.push(frame(12, g: 2), context: c, received: 1))
  XCTAssertEqual(pump.snapshot.lastRecoveryReason, "frameGap")
  pump.push(frame(20, key: true, g: 2), context: c, received: 1)
  XCTAssertFalse(pump.push(frame(999, key: true, g: 1), context: c, received: 1))
  scheduler.run()
  XCTAssertEqual(consumed.count, 2); XCTAssertEqual(try! VideoConfig(consumed[0].payload).generation, 2)
  var r = ByteReader(consumed[1].payload); XCTAssertEqual(try! r.u32(), 2); XCTAssertEqual(try! r.u64(), 20)
  XCTAssertEqual(requests, 1)
 }
 func testExpiredInFlightFrameCannotDiscardNewGenerationIDR() {
  let scheduler = VideoPumpScheduler(), c = context(); var now: UInt64 = 1, requests = 0, fresh = 0
  let pump = VideoDecodePump(maxFrameAge: 250, clock: { now }, schedule: scheduler.enqueue)
  pump.activate(c, consume: { f, _, permit in
   guard f.type == .videoFrame else { return }
   var reader = ByteReader(f.payload); let generation = try! reader.u32()
   if generation == 1 {
    now = 300
    pump.push(self.config(g: 2), context: c, received: now)
    pump.push(self.frame(10, key: true, g: 2), context: c, received: now)
    XCTAssertFalse(permit())
   } else if permit() { fresh += 1 }
  }, reset: {}, recovery: { requests += 1 })
  pump.push(config(), context: c, received: now); pump.push(frame(1, key: true), context: c, received: now)
  scheduler.run()
  XCTAssertEqual(fresh, 1); XCTAssertEqual(requests, 0); XCTAssertFalse(pump.snapshot.waitingForIDR)
 }

 func testKeyframeRetriesStopEvenIfNoIDRArrivesOrSendFails() {
  var retry = VideoKeyframeRetry(), accepted = 0
  for tick in 0..<10000 { if retry.takeAttempt(now: UInt64(tick) * 10_000_000) { accepted += 1 } }
  XCTAssertEqual(accepted, 8); XCTAssertEqual(retry.attempts, 8)
  retry = VideoKeyframeRetry()
  XCTAssertTrue(retry.takeAttempt(now: 100)); XCTAssertFalse(retry.takeAttempt(now: 99))
  XCTAssertFalse(retry.takeAttempt(now: 250_000_099)); XCTAssertTrue(retry.takeAttempt(now: 250_000_100))
 }
 func testLateDecoderFailureCannotInvalidateNewConfiguration() {
  let scheduler = VideoPumpScheduler(), c = context()
  let pump = VideoDecodePump(clock: { 1 }, schedule: scheduler.enqueue)
  pump.activate(c, consume: { _, _, _ in }, reset: {}, recovery: {})
  pump.push(config(), context: c, received: 1); scheduler.run()
  pump.push(config(g: 2), context: c, received: 1); pump.push(frame(10, key: true, g: 2), context: c, received: 1)
  pump.invalidate(c, generation: 1)
  XCTAssertFalse(pump.snapshot.waitingForIDR); XCTAssertEqual(pump.snapshot.pendingFrames, 1)
 }

 func testExpiredInFlightFrameCannotDiscardFreshIDRInSameConfiguration() {
  let scheduler = VideoPumpScheduler(), c = context(); var now: UInt64 = 1, requests = 0, fresh = 0
  let pump = VideoDecodePump(maxFrameAge: 250, clock: { now }, schedule: scheduler.enqueue)
  pump.activate(c, consume: { f, _, permit in
   guard f.type == .videoFrame else { return }
   var reader = ByteReader(f.payload); _ = try! reader.u32(); let id = try! reader.u64()
   if id == 1 {
    now = 300
    pump.push(self.frame(10, key: true), context: c, received: now)
    XCTAssertFalse(permit())
   } else if permit() { fresh += 1 }
  }, reset: {}, recovery: { requests += 1 })
  pump.push(config(), context: c, received: now); pump.push(frame(1, key: true), context: c, received: now)
  scheduler.run()
  XCTAssertEqual(fresh, 1); XCTAssertEqual(requests, 0); XCTAssertFalse(pump.snapshot.waitingForIDR)
 }
 func testRecoveryRetiresInFlightPresentationBeforeFreshIDRArrives() {
  let scheduler = VideoPumpScheduler(), c = context(); var permission: (() -> Bool)?
  let pump = VideoDecodePump(clock: { 1 }, schedule: scheduler.enqueue)
  pump.activate(c, consume: { f, _, permit in
   guard f.type == .videoFrame else { return }
   permission = permit
   pump.invalidate(c)
   XCTAssertFalse(permit(), "discarded reference chain must not publish a late decoded picture")
  }, reset: {}, recovery: {})
  pump.push(config(), context: c, received: 1); pump.push(frame(1, key: true), context: c, received: 1)
  scheduler.run()
  XCTAssertFalse(permission!()); XCTAssertTrue(pump.snapshot.waitingForIDR)
 }

 func testLateDecoderFailureCannotInvalidateNewIDRInSameConfiguration() {
  let scheduler = VideoPumpScheduler(), c = context()
  let pump = VideoDecodePump(clock: { 1 }, schedule: scheduler.enqueue)
  pump.activate(c, consume: { _, _, _ in }, reset: {}, recovery: {})
  pump.push(config(), context: c, received: 1)
  pump.push(frame(1, key: true), context: c, received: 1); scheduler.run()
  pump.push(frame(10, key: true), context: c, received: 1)
  pump.invalidate(c, generation: 1, frameID: 1)
  XCTAssertFalse(pump.snapshot.waitingForIDR); XCTAssertEqual(pump.snapshot.pendingFrames, 1)
  pump.invalidate(c, generation: 1, frameID: 10)
  XCTAssertTrue(pump.snapshot.waitingForIDR); XCTAssertEqual(pump.snapshot.pendingFrames, 0)
 }

}
