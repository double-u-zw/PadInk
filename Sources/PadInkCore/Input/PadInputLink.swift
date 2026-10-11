import Foundation

/// Immutable identity frozen on the capture thread and carried to the input queue.
public struct InputContext: Equatable {
 public let attachmentID: UUID, generation: UInt32
 public init(attachmentID: UUID, generation: UInt32) { self.attachmentID = attachmentID; self.generation = generation }
 public init(_ attachment: Attachment) { self.init(attachmentID: attachment.attachmentID, generation: attachment.generation) }
 /// MetalRenderer uses this exact callback at submission, then invokes it on the main thread.
 public static func presentedCallback(context: InputContext?, current: @escaping () -> InputContext?, presented: @escaping () -> Void) -> () -> Void {
  { guard let context, context == current() else { return }; presented() }
 }
}

fileprivate struct InputActionKey {
 let kind: InputActionKind, gesture: UInt64, sequence: UInt32, geometry: UInt32?
 static func pencil(_ s: PencilSample) -> Self { Self(kind: .pencil, gesture: s.stroke, sequence: UInt32(clamping: s.sequence), geometry: s.geometryGeneration) }
 static func touch(_ e: TouchEvent) -> Self {
  let kind: InputActionKind
  switch e.kind { case .pointer: kind = .pointer; case .scroll: kind = .scroll; case .magnify: kind = .magnify }
  return Self(kind: kind, gesture: e.gestureID, sequence: e.sequence, geometry: e.geometryGeneration)
 }
 static func geometry(_ g: PresentedGeometry) -> Self { Self(kind: .geometry, gesture: 0, sequence: 0, geometry: g.generation) }
 static func state(_ state: (UInt64, UInt32)?, pencil: Bool) -> Self { Self(kind: pencil ? .pencilGesture : .touchGesture, gesture: state?.0 ?? 0, sequence: state?.1 ?? 0, geometry: nil) }
}

/// Local source-side limits; clocks are never compared across devices. Healthy input is FIFO,
/// including every actual/coalesced Pencil point and its terminal. Overflow cancels a whole
/// gesture rather than making a sequence gap. Only an uncompleted stream write closes A.
public struct PadInputSendPolicy {
 public var maxQueueAge: UInt64 = 100_000_000, writeStallTimeout: UInt64 = 250_000_000
 public var maxPendingBytes = 64 << 10, maxPendingFrames = 256
 public init() {}
}

public struct PadInputQueueSnapshot {
 public let captureFrames: Int, captureBytes: Int, pendingFrames: Int, pendingBytes: Int, inFlightBytes: Int
 public let oldestAgeMilliseconds: Double, droppedGestures: UInt64, stalls: UInt64
}

/// Confined to the attachment/input queue. It borrows the attachment, without another session model.
public final class PadInputLink {
 public private(set) var attachment: Attachment?
 public private(set) var pencilGesture: (UInt64, UInt32)?, touchGesture: (UInt64, UInt32)?
 private var lastKeepalive: UInt64 = 0
 private let diagnostics: Diagnostics, clock: () -> UInt64
 public let sendPolicy: PadInputSendPolicy
 /// Local rejection uses the same notice as Mac rejection; the coordinator checks capture identity
 /// before ending UIKit contact. A slow write reports separately because it requires reconnecting.
 public var onRejected: ((InputContext, GestureNotice) -> Void)?, onStall: ((InputContext) -> Void)?
 private struct Packet {
  let type: MessageType, payload: Data, context: InputContext, key: InputActionKey
  let queuedAt: UInt64
  let capturedAt: UInt64?, samples: [PencilSample], terminal: Bool
  var bytes: Int { PINK2.headerSize + payload.count }
 }
 private var pending: [Packet] = [], inFlight: (id: UUID, packet: Packet, sentAt: UInt64)?
 private var cancelledPencil: UInt64 = 0, cancelledTouch: UInt64 = 0
 private var wirePencil: InputActionKey?, wireTouch: InputActionKey?
 private var droppedGestures: UInt64 = 0, stalls: UInt64 = 0
 fileprivate var captureSnapshot: (() -> (frames: Int, bytes: Int, oldest: UInt64?))?
 public var queueSnapshot: PadInputQueueSnapshot {
  let capture = captureSnapshot?() ?? (frames: 0, bytes: 0, oldest: nil), now = clock()
  let oldest = ([capture.oldest, inFlight?.sentAt] + pending.map(\.capturedAt)).compactMap { $0 }.min()
  return PadInputQueueSnapshot(captureFrames: capture.frames, captureBytes: capture.bytes, pendingFrames: pending.count,
   pendingBytes: pending.reduce(0) { $0 + $1.bytes }, inFlightBytes: inFlight?.packet.bytes ?? 0,
   oldestAgeMilliseconds: oldest.map { now >= $0 ? Double(now - $0) / 1e6 : 0 } ?? 0, droppedGestures: droppedGestures, stalls: stalls)
 }
 public var queuedInputFrames: Int { pending.count + (inFlight == nil ? 0 : 1) }
 public var queuedInputBytes: Int { pending.reduce(0) { $0 + $1.bytes } + (inFlight?.packet.bytes ?? 0) }
 public init(diagnostics: Diagnostics, policy: PadInputSendPolicy = PadInputSendPolicy(), clock: @escaping () -> UInt64 = { MonotonicClock.now }) {
  self.diagnostics = diagnostics; sendPolicy = policy; self.clock = clock
 }
 fileprivate func captureDequeued(context: InputContext?, key: InputActionKey, at: UInt64) {
  let now = clock()
  diagnostics.performance.record(PerformanceEvent("input.mailbox", time: now, generation: UInt64(context?.generation ?? 0), attachment: context?.attachmentID, item: key.gesture, sample: UInt64(key.sequence), start: at, end: now))
 }
 fileprivate var captureTime: UInt64 { clock() }

 public func adopt(_ a: Attachment) {
  if attachment.map(InputContext.init) != InputContext(a) { clearGestures(); clearSending() }
  attachment = a
 }
 public func ended(_ a: Attachment) {
  guard attachment === a else { return }
  attachment = nil; clearGestures(); clearSending()
 }
 private func clearGestures() { pencilGesture = nil; touchGesture = nil; lastKeepalive = 0 }
 private func clearSending() { pending.removeAll(); inFlight = nil; cancelledPencil = 0; cancelledTouch = 0; wirePencil = nil; wireTouch = nil }
 private func cancelled(_ id: UInt64) -> Bool { id != 0 && id <= (id & (1 << 63) == 0 ? cancelledPencil : cancelledTouch) }
 private func expired(_ capturedAt: UInt64?) -> Bool { capturedAt.map { clock() >= $0 && clock() - $0 > sendPolicy.maxQueueAge } ?? false }
 fileprivate func record(_ stage: InputActionStage, context: InputContext?, key: InputActionKey, reason: InputActionReason? = nil) {
  diagnostics.performance.record(PerformanceEvent("input.action", generation: UInt64(context?.generation ?? 0), attachment: context?.attachmentID, item: key.gesture, sample: UInt64(key.sequence), code: String(describing: stage) + ":" + (reason.map { String(describing: $0) } ?? "ok")))
  diagnostics.action(stage, context: context, kind: key.kind, gesture: key.gesture, sequence: key.sequence, geometryGeneration: key.geometry, reason: reason, time: clock())
 }
 private func admit(_ context: InputContext?, key: InputActionKey) -> Attachment? {
  guard let context else { record(.drop, context: nil, key: key, reason: .nilContext); return nil }
  guard let a = attachment else { record(.drop, context: context, key: key, reason: .noAttachment); return nil }
  guard context == InputContext(a) else { record(.drop, context: context, key: key, reason: .identityMismatch); return nil }
  guard a.ended == nil else { record(.drop, context: context, key: key, reason: .attachmentEnded); return nil }
  // Readiness belongs to Attachment.send: a B-only rebuild must not add an input gate here.
  record(.admission, context: context, key: key); return a
 }
 private func send(_ type: MessageType, payload: Data, through a: Attachment, context: InputContext?, key: InputActionKey,
  capturedAt: UInt64? = nil, samples: [PencilSample] = [], terminal: Bool = false) -> Bool {
  guard let context, !checkStall(), a.ended == nil else { return false }
  if capturedAt != nil, cancelled(key.gesture) { record(.drop, context: context, key: key, reason: .gestureCancelled); return false }
  if expired(capturedAt) { cancelGesture(key, context: context, reason: .captureQueueExpired); return false }
  let packet = Packet(type: type, payload: payload, context: context, key: key, queuedAt: clock(), capturedAt: capturedAt, samples: samples, terminal: terminal)
  if pending.count >= sendPolicy.maxPendingFrames || pending.reduce(0, { $0 + $1.bytes }) + packet.bytes > sendPolicy.maxPendingBytes {
   let keys = pending.map(\.key) + [key]
   cancelThrough(keys: keys, context: context, reason: .sendQueueOverflow)
   return false
  }
  pending.append(packet); drain(); return true
 }
 private func drain() {
  guard inFlight == nil, let a = attachment, a.ended == nil else { return }
  while !pending.isEmpty {
   let packet = pending.removeFirst()
   guard packet.context == InputContext(a) else { continue }
   if packet.capturedAt != nil, cancelled(packet.key.gesture) { continue }
   if expired(packet.capturedAt) { cancelGesture(packet.key, context: packet.context, reason: .captureQueueExpired); return }
   let sent = clock()
   diagnostics.performance.record(PerformanceEvent("input.sendQueue", time: sent, generation: UInt64(packet.context.generation), attachment: packet.context.attachmentID, item: packet.key.gesture, sample: UInt64(packet.key.sequence), start: packet.queuedAt, end: sent, depth: pending.count, bytes: queuedInputBytes, count: packet.samples.count))
   let id = UUID(), sentAt = clock(); inFlight = (id, packet, sentAt)
   let accepted = a.send(packet.type, payload: packet.payload, on: .controlInput) { [weak self, weak a] error in
    guard let self, let a, self.attachment === a, self.inFlight?.id == id else { return }
    if self.checkStall() { return }
    self.inFlight = nil
    if error != nil { self.stopWriter(a); return }
    self.drain()
   }
   record(accepted ? .sendAdmitted : .drop, context: packet.context, key: packet.key, reason: accepted ? nil : .connectionUnavailable)
   guard accepted else { inFlight = nil; continue }
   if packet.type == .pencil {
    wirePencil = packet.terminal ? nil : packet.key
    for sample in packet.samples {
     if sentAt >= sample.timestamp { diagnostics.mark("input.captureToSend", session: UInt64(a.generation), value: Double(sentAt - sample.timestamp) / 1e6) }
     diagnostics.mark("input.send", session: UInt64(a.generation), sample: sample)
    }
   } else if [.pointer, .scroll, .magnify].contains(packet.type) { wireTouch = packet.terminal ? nil : packet.key }
   return
  }
 }
 /// Bytes already handed to ByteStream/the OS cannot be removed or replaced with INPUT_CANCEL.
 /// Stop the old attachment before its unsent FIFO is resumed; peer link loss performs safe release.
 /// Existing 250ms tick plus ingress/completion checks detect a stationary write within <500ms.
 @discardableResult private func checkStall() -> Bool {
  guard let current = inFlight, clock() >= current.sentAt, clock() - current.sentAt >= sendPolicy.writeStallTimeout, let a = attachment else { return false }
  stopWriter(a); return true
 }
 private func stopWriter(_ a: Attachment) {
  let context = InputContext(a)
  diagnostics.mark("input.senderStall", session: UInt64(a.generation), state: "control write did not drain", value: Double(queuedInputBytes))
  stalls += 1; clearGestures(); clearSending(); onStall?(context); a.close()
 }
 fileprivate func captureOverflow(_ keys: [InputActionKey], context: InputContext?) {
  guard let first = keys.first, admit(context, key: first) != nil, let context else { return }
  cancelThrough(keys: keys, context: context, reason: .captureQueueOverflow)
 }
 private func cancelThrough(keys: [InputActionKey], context: InputContext, reason: InputActionReason) {
  let pencil = keys.filter { $0.gesture != 0 && $0.gesture & (1 << 63) == 0 }.max { $0.gesture < $1.gesture }
  let touch = keys.filter { $0.gesture & (1 << 63) != 0 }.max { $0.gesture < $1.gesture }
  let floors = [pencil, touch].compactMap { $0 }
  let matches: (InputActionKey) -> Bool = { key in floors.contains { ($0.gesture & (1 << 63)) == (key.gesture & (1 << 63)) && key.gesture <= $0.gesture } }
  // Unsubmitted gestures need no wire cancel. Notify only the current source gesture(s) and
  // gestures actually handed to A; this leaves at most four small priority cancellation frames.
  let affected = [wirePencil, wireTouch, inFlight?.packet.key].compactMap { $0 }.filter(matches) + floors
  for packet in pending where packet.capturedAt != nil && matches(packet.key) { record(.drop, context: context, key: packet.key, reason: reason) }
  pending.removeAll { $0.capturedAt != nil && matches($0.key) }
  var seen = Set<UInt64>()
  for key in affected.sorted(by: { $0.gesture < $1.gesture }) where seen.insert(key.gesture).inserted {
   cancelGesture(key, context: context, reason: reason)
  }
 }
 private func cancelGesture(_ key: InputActionKey, context: InputContext, reason: InputActionReason, notifyPeer: Bool = true) {
  guard key.gesture != 0 else { return }
  record(.drop, context: context, key: key, reason: reason)
  let wasCancelled = cancelled(key.gesture)
  if key.gesture & (1 << 63) == 0 { cancelledPencil = max(cancelledPencil, key.gesture) } else { cancelledTouch = max(cancelledTouch, key.gesture) }
  let isPencil = key.gesture & (1 << 63) == 0
  let affected: (UInt64) -> Bool = { id in id != 0 && (id & (1 << 63) == 0) == isPencil && id <= key.gesture }
  pending.removeAll { $0.capturedAt != nil && affected($0.key.gesture) }
  if pencilGesture.map({ affected($0.0) }) == true { pencilGesture = nil }
  if touchGesture.map({ affected($0.0) }) == true { touchGesture = nil }
  let wire = (isPencil ? wirePencil : wireTouch).flatMap { affected($0.gesture) ? $0 : nil }
  if wire != nil { if isPencil { wirePencil = nil } else { wireTouch = nil } }
  guard !wasCancelled else { return }
  if notifyPeer { droppedGestures += 1 }
  let notice = GestureNotice(gestureID: key.gesture, reason: .staleSample)
  if notifyPeer {
   // Only a gesture actually handed to A needs a peer cancel. A later expired gesture also
   // retires an older submitted contact whose terminal was still pending. At most one cancel
   // per input kind is pending; thousands of unsent expired gestures add no wire backlog.
   if let wire {
    let release = GestureNotice(gestureID: wire.gesture, reason: .staleSample)
    pending.insert(Packet(type: .inputCancel, payload: release.encoded(), context: context, key: wire, queuedAt: clock(), capturedAt: nil, samples: [], terminal: true), at: 0)
   }
   onRejected?(context, notice)
  }
  drain()
 }
 public func sendPencil(_ samples: [PencilSample], context: InputContext?, capturedAt: UInt64? = nil) {
  guard let first = samples.first else { return }; let key = InputActionKey.pencil(first)
  guard let a = admit(context, key: key) else { return }
  guard let batch = try? PencilBatch(samples), let payload = try? batch.encoded() else { record(.drop, context: context, key: key, reason: .invalidPayload); return }
  _ = send(.pencil, payload: payload, through: a, context: context, key: key, capturedAt: capturedAt ?? clock(), samples: samples, terminal: batch.batchFlags & 2 != 0)
 }
 public func sendTouch(_ event: TouchEvent, context: InputContext?, capturedAt: UInt64? = nil) {
  let key = InputActionKey.touch(event)
  guard let a = admit(context, key: key) else { return }
  guard let payload = try? event.encoded() else { record(.drop, context: context, key: key, reason: .invalidPayload); return }
  _ = send(event.kind.message, payload: payload, through: a, context: context, key: key, capturedAt: capturedAt ?? clock(), terminal: event.phase == .ended || event.phase == .cancelled)
 }
 public func sendGeometry(_ geometry: PresentedGeometry, context: InputContext?) {
  let key = InputActionKey.geometry(geometry)
  guard let a = admit(context, key: key) else { return }
  _ = send(.presentedGeometry, payload: geometry.encoded(), through: a, context: context, key: key)
 }
 public func pencilGestureChanged(_ state: (UInt64, UInt32)?, context: InputContext?, capturedAt: UInt64? = nil) {
  let key = InputActionKey.state(state, pencil: true)
  guard admit(context, key: key) != nil, let context else { return }
  if state != nil, expired(capturedAt) { cancelGesture(key, context: context, reason: .captureQueueExpired); return }
  if state != nil, cancelled(key.gesture) { return }
  pencilGesture = state; lastKeepalive = clock(); record(.gestureState, context: context, key: key)
 }
 public func touchGestureChanged(_ state: (UInt64, UInt32)?, context: InputContext?, capturedAt: UInt64? = nil) {
  let key = InputActionKey.state(state, pencil: false)
  guard admit(context, key: key) != nil, let context else { return }
  if state != nil, expired(capturedAt) { cancelGesture(key, context: context, reason: .captureQueueExpired); return }
  if state != nil, cancelled(key.gesture) { return }
  touchGesture = state; record(.gestureState, context: context, key: key)
 }
 public func rejected(_ notice: GestureNotice) {
  guard let context = attachment.map(InputContext.init) else { return }
  let key = InputActionKey(kind: notice.gestureID & (1 << 63) == 0 ? .pencil : .pointer, gesture: notice.gestureID, sequence: 0, geometry: nil)
  cancelGesture(key, context: context, reason: .gestureCancelled, notifyPeer: false)
 }
 /// Keepalive remains independent of UIKit movement and the main run loop.
 public func tick() {
  guard !checkStall() else { return }
  let now = clock()
  guard let a = attachment, let (gesture, seq) = pencilGesture ?? touchGesture, now &- lastKeepalive >= 200_000_000 else { return }
  let context = InputContext(a), key = InputActionKey(kind: .keepalive, gesture: gesture, sequence: max(1, seq), geometry: nil)
  guard admit(context, key: key) != nil else { return }
  lastKeepalive = now
  _ = send(.gestureKeepalive, payload: GestureKeepalive(gestureID: gesture, lastSampleSequence: max(1, seq)).encoded(), through: a, context: context, key: key)
 }
}

/// A bounded capture mailbox keeps sample arrays out of an unbounded queue of closures. One
/// wake per capture identity drains FIFO. Replacing identity retires its data immediately; a
/// delayed old wake cannot drain the replacement's mailbox. Capacity is 64KiB/256 captured jobs,
/// independently of the sender's 64KiB/256 pending frames, up to two 52-byte priority cancels,
/// and one <=9.1KiB Pencil frame in flight. A running capture drain can hold one further batch.
private final class PadInputCaptureMailbox {
 struct Job { let context: InputContext?, key: InputActionKey, bytes: Int, capturedAt: UInt64, run: () -> Void }
 private final class State {
  let context: InputContext?; var jobs: [Job] = [], bytes = 0, scheduled = false
  var pencilFloor: UInt64 = 0, touchFloor: UInt64 = 0
  init(_ context: InputContext?) { self.context = context }
 }
 private let lock = NSLock(), link: PadInputLink, enqueue: (@escaping () -> Void) -> Void
 private var current: State?
 init(link: PadInputLink, enqueue: @escaping (@escaping () -> Void) -> Void) { self.link = link; self.enqueue = enqueue }
 func snapshot() -> (frames: Int, bytes: Int, oldest: UInt64?) {
  lock.lock(); defer { lock.unlock() }; return (current?.jobs.count ?? 0, current?.bytes ?? 0, current?.jobs.map(\.capturedAt).min())
 }
 func append(_ job: Job) {
  lock.lock()
  if current?.context != job.context {
   let old = current?.jobs ?? []; current?.jobs.removeAll(); current?.bytes = 0
   for dropped in old { link.record(.drop, context: dropped.context, key: dropped.key, reason: .identityMismatch) }
   current = State(job.context)
  }
  if current == nil { current = State(job.context) }
  let state = current!
  let floor = job.key.gesture & (1 << 63) == 0 ? state.pencilFloor : state.touchFloor
  if job.key.gesture != 0, job.key.gesture <= floor {
   lock.unlock(); link.record(.drop, context: job.context, key: job.key, reason: .gestureCancelled); return
  }
  if state.jobs.count >= link.sendPolicy.maxPendingFrames || state.bytes + job.bytes > link.sendPolicy.maxPendingBytes {
   let keys = state.jobs.map(\.key) + [job.key]
   let pencil = keys.filter { $0.gesture != 0 && $0.gesture & (1 << 63) == 0 }.max { $0.gesture < $1.gesture }
   let touch = keys.filter { $0.gesture & (1 << 63) != 0 }.max { $0.gesture < $1.gesture }
   let floors = [pencil, touch].compactMap { $0 }
   state.pencilFloor = max(state.pencilFloor, pencil?.gesture ?? 0); state.touchFloor = max(state.touchFloor, touch?.gesture ?? 0)
   // No partial sample sequence survives overflow. The last geometry is retained so the next
   // fresh gesture can use the current presentation, rather than replaying superseded layouts.
   let geometry = (state.jobs + [job]).last { $0.key.kind == .geometry }
   state.jobs.removeAll(); state.bytes = 0
   if let geometry { state.jobs.append(geometry); state.bytes += geometry.bytes }
   if let key = floors.first {
    let context = job.context
    state.jobs.append(Job(context: context, key: key, bytes: 64, capturedAt: link.captureTime, run: { [link] in link.captureOverflow(floors, context: context) })); state.bytes += 64
   }
  } else { state.jobs.append(job); state.bytes += job.bytes }
  let schedule = !state.scheduled; state.scheduled = true; lock.unlock()
  if schedule { enqueue { [self, state] in drain(state) } }
 }
 private func drain(_ state: State) {
  lock.lock(); let jobs = state.jobs; state.jobs.removeAll(); state.bytes = 0; state.scheduled = false; lock.unlock()
  for job in jobs { link.captureDequeued(context: job.context, key: job.key, at: job.capturedAt); job.run() }
 }
}

/// Exact capture-to-queue wiring used by PadCoordinator; capture age is frozen before queueing.
public struct PadInputCallbacks {
 public let pencil: ([PencilSample]) -> Void, touch: (TouchEvent) -> Void, geometry: (PresentedGeometry) -> Void
 public let pencilGesture: (((UInt64, UInt32)?) -> Void), touchGesture: (((UInt64, UInt32)?) -> Void)
 public init(link: PadInputLink, context: @escaping () -> InputContext?, enqueue: @escaping (@escaping () -> Void) -> Void) {
  let mailbox = PadInputCaptureMailbox(link: link, enqueue: enqueue)
  link.captureSnapshot = { [weak mailbox] in mailbox?.snapshot() ?? (0, 0, nil) }
  func capture(_ key: InputActionKey, bytes: Int, run: @escaping (InputContext?, UInt64) -> Void) {
   let captured = context(), at = link.captureTime
   link.record(.capture, context: captured, key: key)
   guard captured != nil else { link.record(.drop, context: nil, key: key, reason: .nilContext); return }
   mailbox.append(.init(context: captured, key: key, bytes: bytes, capturedAt: at, run: { run(captured, at) }))
  }
  pencil = { samples in
   guard let first = samples.first else { return }
   capture(.pencil(first), bytes: PINK2.headerSize + PencilBatch.headerSize + samples.count * MemoryLayout<PencilSample>.stride) { context, at in
    link.sendPencil(samples, context: context, capturedAt: at)
   }
  }
  touch = { event in capture(.touch(event), bytes: 80) { link.sendTouch(event, context: $0, capturedAt: $1) } }
  geometry = { value in capture(.geometry(value), bytes: 64) { context, _ in link.sendGeometry(value, context: context) } }
  pencilGesture = { state in capture(.state(state, pencil: true), bytes: 48) { link.pencilGestureChanged(state, context: $0, capturedAt: $1) } }
  touchGesture = { state in capture(.state(state, pencil: false), bytes: 48) { link.touchGestureChanged(state, context: $0, capturedAt: $1) } }
 }
}
