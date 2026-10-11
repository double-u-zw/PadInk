import Foundation

/// Local facts each side puts in its HELLO / HELLO_ACK.
public struct LocalIdentity: Equatable {
 public var appVersion: String, deviceID: Data, displayName: String
 public var capabilities: Capabilities, signingExpiry: UInt64
 public var drawableWidth: UInt32, drawableHeight: UInt32
 public init(appVersion: String, deviceID: Data, displayName: String = "", capabilities: Capabilities = [], signingExpiry: UInt64 = 0, drawableWidth: UInt32 = 0, drawableHeight: UInt32 = 0) {
  self.appVersion = appVersion; self.deviceID = deviceID; self.displayName = displayName; self.capabilities = capabilities
  self.signingExpiry = signingExpiry; self.drawableWidth = drawableWidth; self.drawableHeight = drawableHeight
 }
}

public struct AttachmentTiming: Equatable {
 public var handshakeTimeout: UInt64 = 3_000_000_000
 public var heartbeatInterval: UInt64 = 1_000_000_000
 public var liveness: LivenessPolicy = .initial
 public init() {}
}

public enum AttachmentEnd: Equatable {
 /// Fault row 7: A failed or went silent. Input must be cancelled (transportLost).
 case dead(AttachmentDeathReason)
 /// Fault row 8.
 case protocolViolation(String)
 case versionMismatch(VersionNegotiation)
 case peerError(ErrorCode)
 case handshakeTimeout
 case peerGoodbye(GoodbyeReason)
 /// Closed by this side; the reason decides what the logical session does next (only a user
 /// disconnect pauses it).
 case closedLocally(GoodbyeReason?)
 /// The iPad accepted a newer attachment from the Mac.
 case replaced
}

public enum AttachmentEvent: Equatable {
 case ready(peer: Hello)
 /// Every non-control frame, stamped with the local time its last bytes arrived from the stream,
 /// before any queueing inside PadInk (InputFreshness).
 case frame(ConnectionKind, Frame, ReceiveStamp)
 case health(AttachmentHealth)
 /// Mac only: B must be re-dialled; call `replaceVideo`. Input is unaffected.
 case videoRebuildNeeded(VideoRebuildReason)
 case videoRebuilt
 case ended(AttachmentEnd)
}

/// One transport attachment: connection A (control + input) and B (video), handshake,
/// heartbeats and liveness (PROTOCOL §1, §4.1, §4.2; ARCHITECTURE §4). Both roles use this class.
/// Not thread-safe by design: every method must run on `queue`, and events are emitted there.
public final class Attachment {
 public var performance: PerformanceRecorder?
 public let transport: TransportKind
 public let role: PeerRole, attachmentID: UUID, generation: UInt32
 public private(set) var peer: Hello?
 public private(set) var ended: AttachmentEnd?
 public private(set) var health: AttachmentHealth = .healthy
 /// Latest RTT measured on A (nanoseconds). Never measured on B (PROTOCOL §1.1).
 public private(set) var controlRTT: UInt64?
 public private(set) var clockEstimate: ClockEstimate?
 public var onEvent: ((AttachmentEvent) -> Void)?

 private let security: AttachmentSecurity?
 private let expectedPeerID: Data?, trustedOnly: Bool
 private let local: LocalIdentity, resumeToken: Data, timing: AttachmentTiming
 private let queue: DispatchQueue, clock: () -> UInt64
 private var links: [ConnectionKind: Link] = [:]
 private var acked: Set<ConnectionKind> = []
 private var liveness: AttachmentLiveness
 private var started: UInt64, nextHeartbeat: UInt64 = 0, nonce: UInt64 = 0, pings: [UInt64: UInt64] = [:]
 private var announcedReady = false
 private var initialFrames: [(ConnectionKind, Frame, ReceiveStamp)] = [], initialFrameBytes = 0
 private var pendingVideo: Link?, pendingVideoSince: UInt64 = 0
 /// Mac video rebuild (fault row 7b): pending since `requestedAt` until B's HELLO_ACK. A rebuild that
 /// does not complete in `rebuildTimeout`, or that the owner reports as failed, is retried after a
 /// bounded exponential backoff. A and Pencil are never touched by any of this.
 private var rebuild: (requestedAt: UInt64, attempt: Int)?, rebuildAttempts = 0, rebuildRetryAt: UInt64 = 0
 public static let rebuildTimeout: UInt64 = 5_000_000_000
 static func rebuildBackoff(_ attempt: Int) -> UInt64 { min(10_000_000_000, 500_000_000 << UInt64(min(max(attempt - 1, 0), 5))) }

 private final class Link {
  let traceID = UUID()
  var firstByteAt: UInt64?
  var decodeRecoveryRequested = false
  let stream: ByteStream; var decoder: FrameDecoder; var sequence: UInt64 = 0
  var localHello: Hello?, peerHello: Hello?, authentication: AttachmentAuthentication?
  var authenticated = false
  init(_ stream: ByteStream, _ kind: ConnectionKind?) { self.stream = stream; decoder = FrameDecoder(connection: kind) }
 }

 public init(role: PeerRole, attachmentID: UUID, generation: UInt32, resumeToken: Data = Data(count: 32), local: LocalIdentity, timing: AttachmentTiming = AttachmentTiming(), security: AttachmentSecurity? = nil, transport: TransportKind = .usb, expectedPeerID: Data? = nil, trustedOnly: Bool = false, queue: DispatchQueue, clock: @escaping () -> UInt64 = { MonotonicClock.now }) {
  self.transport = transport; self.expectedPeerID = expectedPeerID; self.trustedOnly = trustedOnly
  self.role = role; self.attachmentID = attachmentID; self.generation = generation; self.resumeToken = resumeToken
  self.security = security; self.local = local; self.timing = timing; self.queue = queue; self.clock = clock
  let now = clock(); started = now; liveness = AttachmentLiveness(now: now, policy: timing.liveness)
 }

 public var isReady: Bool { usable(.controlInput) && usable(.video) }
 /// A connection is usable once its own handshake completed; A keeps carrying input while B is rebuilt.
 private func usable(_ kind: ConnectionKind) -> Bool { ended == nil && peer != nil && acked.contains(kind) && (security == nil || links[kind]?.authenticated == true) }
 private func announceReadiness(kind: ConnectionKind) {
  guard isReady else { return }
  if !announcedReady { liveness = AttachmentLiveness(now: clock(), policy: timing.liveness); announcedReady = true; onEvent?(.ready(peer: peer!))
   let frames = initialFrames; initialFrames.removeAll(); initialFrameBytes = 0
   for (connection, frame, stamp) in frames where ended == nil { onEvent?(.frame(connection, frame, stamp)) }
  } else if kind == .video { onEvent?(.videoRebuilt) }
 }

 // MARK: Mac (initiator)

 /// Mac: both streams are connected; send HELLO on each and wait for HELLO_ACK.
 public func start(control: ByteStream, video: ByteStream) {
  precondition(role == .mac)
  for (kind, stream) in [(ConnectionKind.controlInput, control), (.video, video)] { install(stream, kind: kind); sendHello(on: kind, ack: false) }
 }

 /// Mac: B was rebuilt after `.videoRebuildNeeded`. Same attachment and session generation.
 public func replaceVideo(_ stream: ByteStream) {
  guard role == .mac, ended == nil else { stream.close(); return }
  links[.video]?.authentication?.cancel(); links[.video]?.stream.close(); acked.remove(.video); install(stream, kind: .video); sendHello(on: .video, ack: false)
 }

 // MARK: iPad (acceptor), driven by PadAttachmentHost

 func adopt(_ stream: ByteStream, decoder: FrameDecoder, hello: Hello) {
  precondition(role == .ipad)
  let link = Link(stream, hello.connection); link.decoder = decoder; link.peerHello = hello
  if hello.connection == .video, announcedReady, security != nil {
   // Stage a replacement until it proves the pair key; strangers cannot evict the live B.
   guard pendingVideo == nil else { stream.close(); return }
   pendingVideo = link; pendingVideoSince = clock(); bind(stream, kind: .video, link: link)
   sendHello(on: .video, ack: true, target: link); beginAuthentication(on: .video, link: link); return
  }
  links[hello.connection]?.authentication?.cancel(); links[hello.connection]?.stream.close()
  links[hello.connection] = link
  bind(stream, kind: hello.connection, link: link)
  if peer == nil { peer = hello }
  sendHello(on: hello.connection, ack: true); acked.insert(hello.connection)
  liveness.received(on: hello.connection, now: clock())
  if hello.connection == .video { liveness.videoRebuilt(now: clock()) }
  beginAuthentication(on: hello.connection, link: link)
  announceReadiness(kind: hello.connection)
 }

 // MARK: Both

 /// Send one frame after the handshake. Returns false if it could not be queued.
 /// `completion` runs on `queue` once the bytes left PadInk's queue (nil error) or failed.
 @discardableResult public func send(_ type: MessageType, payload: Data = Data(), flags: FrameFlags? = nil, on kind: ConnectionKind, completion: ((Error?) -> Void)? = nil) -> Bool {
  guard announcedReady, usable(kind), let link = links[kind] else { return false }
  return enqueue(link, kind: kind, Frame(type: type, flags: flags, generation: generation, sequence: link.sequence + 1, timestamp: clock(), payload: payload), completion: completion)
 }

 /// iPad decoder recovery: retire only B so the Mac's existing redial/backoff rebuilds it.
 /// Retain A and its authentication; this is not a user disconnect or a new pairing.
 @discardableResult public func restartVideoAfterDecodeFailure() -> Bool {
  guard role == .ipad, ended == nil, announcedReady, let link = links[.video],
        !link.decodeRecoveryRequested else { return false }
  link.decodeRecoveryRequested = true
  link.stream.close()
  liveness.connectionFailed(.video)
  return true
 }

 public func queuedBytes(on kind: ConnectionKind) -> Int { links[kind]?.stream.queuedBytes ?? 0 }

 /// Drive timers: handshake timeout, heartbeats, liveness. Call at least every 250 ms.
 public func tick() {
  guard ended == nil else { return }
  let now = clock()
  if security != nil, !announcedReady {
   if now >= started &+ (trustedOnly ? timing.handshakeTimeout : 120_000_000_000) { finish(.handshakeTimeout) }; return
  }
  if let p = pendingVideo, now >= pendingVideoSince &+ Self.rebuildTimeout { discardPendingVideo(p) }
  if !isReady {
   if now >= started &+ timing.handshakeTimeout, !(role == .mac && acked.contains(.controlInput) && peer != nil) { finish(.handshakeTimeout); return }
   if role == .ipad || !acked.contains(.controlInput) { return }
  }
  if now >= nextHeartbeat {
   nextHeartbeat = now &+ timing.heartbeatInterval
   nonce &+= 1; pings[nonce] = now; if pings.count > 16 { pings.remove(at: pings.startIndex) }
   for kind in [ConnectionKind.controlInput, .video] where usable(kind) {
    // Mac skips B heartbeats while video bytes are queued: frames already prove progress.
    if kind == .video, role == .mac, queuedBytes(on: .video) > 0 { continue }
    if let link = links[kind] { enqueue(link, kind: kind, Frame(type: .heartbeat, generation: generation, sequence: link.sequence + 1, timestamp: now, payload: Heartbeat(nonce: nonce).encoded())) }
   }
  }
  if let pending = rebuild, now >= pending.requestedAt &+ Self.rebuildTimeout { videoRebuildFailed() }
  liveness.videoSendQueue(queuedBytes: queuedBytes(on: .video), drained: false, now: now)
  let verdict = liveness.evaluate(now: now)
  if verdict != health { health = verdict; onEvent?(.health(verdict)) }
  switch verdict {
  case .attachmentDead(let reason): finish(.dead(reason))
  case .rebuildVideo(let reason) where role == .mac && rebuild == nil && now >= rebuildRetryAt:
   rebuild = (now, rebuildAttempts + 1); acked.remove(.video)
   if let old = links[.video] { old.authentication?.cancel(); old.stream.onData = nil; old.stream.onClose = nil; old.stream.close() }
   onEvent?(.videoRebuildNeeded(reason))
  default: break
  }
 }

 /// Mac: the owner could not open a new B (e.g. the redial found no device). Retry after backoff.
 public func videoRebuildFailed() {
  guard role == .mac, ended == nil, let pending = rebuild else { return }
  rebuild = nil; rebuildAttempts = pending.attempt; rebuildRetryAt = clock() &+ Self.rebuildBackoff(pending.attempt)
  if let link = links[.video], !usable(.video) { link.authentication?.cancel(); link.stream.onData = nil; link.stream.onClose = nil; link.stream.close() }
  liveness.connectionFailed(.video)
 }

 /// The owner found a malformed payload inside a well-framed message (fault row 8).
 public func abort(protocolViolation why: String) {
  finish(.protocolViolation(why), error: ErrorMessage(code: .protocolViolation, faultRow: 8, detail: why))
 }

 /// Orderly local close; sends GOODBYE when ready.
 public func close(_ reason: GoodbyeReason? = nil) {
  if let reason, usable(.controlInput) { send(.goodbye, payload: Goodbye(reason: reason).encoded(), on: .controlInput) }
  finish(.closedLocally(reason))
 }

 func finish(_ end: AttachmentEnd, error: ErrorMessage? = nil) {
  performance?.record(PerformanceEvent("route.ended", generation: UInt64(generation), attachment: attachmentID, code: end.diagnosticFault.reason))
  guard ended == nil else { return }
  ended = end
  if let error, let link = links[.controlInput] { _ = enqueue(link, kind: .controlInput, Frame(type: .error, generation: generation, sequence: link.sequence + 1, timestamp: clock(), payload: error.encoded()), force: true) }
  if let p = pendingVideo { discardPendingVideo(p) }
  for link in links.values { link.authentication?.cancel(); link.stream.onData = nil; link.stream.onClose = nil; link.stream.close() }
  onEvent?(.ended(end))
 }

 // MARK: Internals

 private func install(_ stream: ByteStream, kind: ConnectionKind) {
  let link = Link(stream, kind); links[kind] = link; bind(stream, kind: kind, link: link); stream.start()
  if kind == .video { liveness.videoRebuilt(now: clock()) }
 }

 public func recordPerformanceRoutes() {
  for (kind, link) in links {
   performance?.record(PerformanceEvent("route.active", generation: UInt64(generation), attachment: attachmentID,
    link: link.traceID, stream: kind.rawValue, code: transport.rawValue + ":" + String(describing: type(of: link.stream))))
  }
 }

 private func bind(_ stream: ByteStream, kind: ConnectionKind, link: Link) {
  // The arrival time is taken here, on the stream's own callback thread, before the hop onto `queue`:
  // time spent waiting behind input injection or video work on that queue counts toward sample age.
  stream.onData = { [weak self, weak link] data in
   guard let self else { return }; let arrival = ReceiveStamp(localTime: self.clock())
   let perf = self.performance, id = self.attachmentID, gen = UInt64(self.generation), linkID = link?.traceID
   perf?.record(PerformanceEvent("stream.callback", time: arrival.localTime, generation: gen, attachment: id, link: linkID, stream: kind.rawValue, bytes: data.count))
   self.queue.async {
    guard let link, self.links[kind] === link || self.pendingVideo === link else {
     perf?.record(PerformanceEvent("stream.drop", generation: gen, attachment: id, link: linkID, stream: kind.rawValue, code: "retiredLink")); return
    }
    let started = self.clock()
    perf?.record(PerformanceEvent("stream.queue", time: started, generation: gen, attachment: id, link: linkID, stream: kind.rawValue, start: arrival.localTime, end: started, bytes: data.count))
    self.receive(data, on: kind, link: link, arrival: arrival)
   }
  }
  stream.onClose = { [weak self, weak link] error in self?.queue.async {
   guard let self, let link else { return }
   if self.pendingVideo === link { self.discardPendingVideo(link); return }
   guard (self.links[kind] === link || self.pendingVideo === link) else { return }; self.streamClosed(kind, error: error)
  } }
 }

 private func streamClosed(_ kind: ConnectionKind, error: Error?) {
  guard ended == nil else { return }
  if kind == .controlInput { finish(.dead(.controlFailed)); return }
  // The replacement B itself closed before its handshake: that rebuild attempt failed.
  if role == .mac, rebuild != nil, !usable(.video) { videoRebuildFailed(); return }
  liveness.connectionFailed(.video); tick()
 }

 private func sendHello(on kind: ConnectionKind, ack: Bool, target: Link? = nil) {
  guard let link = target ?? links[kind] else { return }
  let h = Hello(connection: kind, role: role, appVersion: local.appVersion, deviceID: local.deviceID, attachmentID: attachmentID, resumeToken: resumeToken, generation: generation, capabilities: local.capabilities, signingExpiry: local.signingExpiry, displayName: local.displayName, drawableWidth: local.drawableWidth, drawableHeight: local.drawableHeight)
  link.localHello = h
  guard let payload = try? h.encoded() else { finish(.protocolViolation("local hello")); return }
  _ = enqueue(link, kind: kind, Frame(type: ack ? .helloAck : .hello, generation: ack ? generation : 0, sequence: link.sequence + 1, timestamp: clock(), payload: payload), force: true)
 }

 private func beginAuthentication(on kind: ConnectionKind, link: Link) {
  guard let security, let local = link.localHello, let peer = link.peerHello, link.authentication == nil else { return }
  let authentication = AttachmentAuthentication(context: security, local: local, peer: peer,
   send: { [weak self, weak link] type, payload in
    guard let self, let link, self.ended == nil, (self.links[kind] === link || self.pendingVideo === link) else { return }
    _ = self.enqueue(link, kind: kind, Frame(type: type, generation: self.generation, sequence: link.sequence + 1, timestamp: self.clock(), payload: payload))
   }, complete: { [weak self, weak link] valid in
    guard let self, let link, self.ended == nil, (self.links[kind] === link || self.pendingVideo === link) else { return }
    guard valid else {
     if self.pendingVideo === link { self.discardPendingVideo(link); return }
     if self.announcedReady, kind == .video { link.stream.close(); self.videoRebuildFailed(); return }
     self.finish(.peerError(.authenticationFailed), error: ErrorMessage(code: .authenticationFailed, faultRow: 8)); return
    }
    if self.pendingVideo === link {
     self.pendingVideo = nil; self.links[.video]?.authentication?.cancel(); self.links[.video]?.stream.close()
     self.links[.video] = link; self.liveness.videoRebuilt(now: self.clock())
    }
    link.authenticated = true
    if kind == .video { self.rebuild = nil; self.rebuildAttempts = 0; self.rebuildRetryAt = 0 }
    self.liveness.received(on: kind, now: self.clock()); self.announceReadiness(kind: kind)
   })
  link.authentication = authentication; authentication.start()
 }

 @discardableResult private func enqueue(_ link: Link, kind: ConnectionKind, _ frame: Frame, force: Bool = false, completion: ((Error?) -> Void)? = nil) -> Bool {
  let began = clock()
  guard ended == nil || force, let data = try? frame.encoded() else { return false }
  let timingClock = clock
  let sent = clock(), perf = performance, id = attachmentID, gen = UInt64(generation), linkID = link.traceID
  perf?.record(PerformanceEvent("wire.encode", time: sent, generation: gen, attachment: id, link: linkID, stream: kind.rawValue, frame: frame.sequence, start: began, end: sent, bytes: data.count))
  perf?.record(PerformanceEvent("wire.send", time: sent, generation: gen, attachment: id, link: linkID, stream: kind.rawValue, frame: frame.sequence, start: frame.timestamp, bytes: data.count, code: String(frame.type.rawValue)))
  if perf?.enabled == true, frame.type == .pencil, let batch = try? PencilBatch(frame.payload) {
   perf?.record(PerformanceEvent("wire.pencil", time: sent, generation: gen, attachment: id, link: linkID, stream: kind.rawValue, frame: frame.sequence, item: batch.gestureID, sample: batch.samples.first.map { UInt64($0.sequence) }, count: batch.samples.count))
  }
  link.sequence = frame.sequence
  link.stream.send(data) { [weak self] error in
   let completed = timingClock()
   perf?.record(PerformanceEvent("wire.writeComplete", time: completed, generation: gen, attachment: id, link: linkID, stream: kind.rawValue, frame: frame.sequence, start: sent, end: completed, code: error == nil ? "ok" : "error"))
   self?.queue.async { guard let self else { return }
    let handled = self.clock()
    perf?.record(PerformanceEvent("wire.completionQueue", time: handled, generation: gen, attachment: id, link: linkID, stream: kind.rawValue, frame: frame.sequence, start: completed, end: handled))
    if self.ended == nil, error == nil, kind == .video, self.links[kind] === link { self.liveness.videoSendQueue(queuedBytes: link.stream.queuedBytes, drained: true, now: self.clock()) }
    completion?(error) }
  }
  if kind == .video, links[kind] === link { liveness.videoSendQueue(queuedBytes: link.stream.queuedBytes, drained: false, now: clock()) }
  return true
 }

 private func discardPendingVideo(_ link: Link) {
  guard pendingVideo === link else { return }; pendingVideo = nil
  link.authentication?.cancel(); link.stream.onData = nil; link.stream.onClose = nil; link.stream.close()
 }

 private func receive(_ data: Data, on kind: ConnectionKind, link: Link, arrival stamp: ReceiveStamp) {
  guard ended == nil else { return }
  if links[kind] === link { liveness.received(on: kind, now: stamp.localTime) }
  let decodeStart = clock(), firstByte = link.firstByteAt ?? stamp.localTime
  let items: [DecodedItem]
  do { items = try link.decoder.feed(data) } catch { if pendingVideo === link { discardPendingVideo(link); return }; finish(.protocolViolation(String(describing: error)), error: ErrorMessage(code: .protocolViolation, faultRow: 8, detail: String(describing: error))); return }
  let decoded = clock()
  performance?.record(PerformanceEvent("wire.parse", time: decoded, generation: UInt64(generation), attachment: attachmentID, link: link.traceID, stream: kind.rawValue, start: decodeStart, end: decoded, bytes: data.count, count: items.count))
  link.firstByteAt = link.decoder.bufferedBytes > 0 ? (items.isEmpty ? firstByte : stamp.localTime) : nil
  for (index, item) in items.enumerated() {
   guard links[kind] === link || pendingVideo === link else { break }
   guard ended == nil, case .frame(let f) = item else { continue }
   performance?.record(PerformanceEvent("wire.receive", time: stamp.localTime, generation: UInt64(generation), attachment: attachmentID, link: link.traceID, stream: kind.rawValue, frame: f.sequence, start: index == 0 ? firstByte : stamp.localTime, end: decoded, bytes: f.payload.count, code: String(f.type.rawValue)))
   handle(f, on: kind, link: link, stamp: stamp)
  }
 }

 private func handle(_ f: Frame, on kind: ConnectionKind, link: Link, stamp: ReceiveStamp) {
  func violation(_ why: String) { if pendingVideo === link { discardPendingVideo(link); return }; finish(.protocolViolation(why), error: ErrorMessage(code: .protocolViolation, faultRow: 8, detail: why)) }
  if pendingVideo === link, f.type != .authProof && f.type != .authResult { return violation("replacement before authentication") }
  switch f.type {
  case .helloAck where role == .mac:
   guard !acked.contains(kind) else { return violation("duplicate ack") }
   guard let h = try? Hello(f.payload) else {
    if let range = try? Hello.versionRange(f.payload) { finish(.versionMismatch(VersionNegotiation.negotiate(local: PINK2.wireVersion...PINK2.wireVersion, remote: range))) } else { violation("ack payload") }; return
   }
   guard f.wireVersion == PINK2.wireVersion else { finish(.versionMismatch(VersionNegotiation.negotiate(local: PINK2.wireVersion...PINK2.wireVersion, remote: h.minWireVersion...h.maxWireVersion))); return }
   guard h.role == .ipad, h.connection == kind, h.attachmentID == attachmentID, h.generation == generation, h.resumeToken == resumeToken, f.generation == generation else { return violation("ack mismatch") }
   if let expectedPeerID, h.deviceID != expectedPeerID { return violation("unexpected peer") }
   if trustedOnly, security?.store.peer(h.deviceID) == nil { return violation("untrusted LAN peer") }
   if let p = peer, p.deviceID != h.deviceID { return violation("device changed") }
   peer = peer ?? h; link.peerHello = h; acked.insert(kind)
   if kind == .video, security == nil { rebuild = nil; rebuildAttempts = 0; rebuildRetryAt = 0 }
   beginAuthentication(on: kind, link: link)
   announceReadiness(kind: kind)
  case .authProof, .authResult:
   guard let authentication = link.authentication, !link.authenticated, f.generation == generation else { return violation("unexpected authentication") }
   authentication.receive(f.type, f.payload)
  case .heartbeat:
   guard usable(kind) else { return violation("heartbeat before authentication") }
   guard let h = try? Heartbeat(f.payload) else { return violation("heartbeat") }
   let now = clock(); enqueue(link, kind: kind, Frame(type: .heartbeatAck, generation: generation, sequence: link.sequence + 1, timestamp: now, payload: HeartbeatAck(nonce: h.nonce, receiveTime: stamp.localTime, sendTime: now).encoded()))
  case .heartbeatAck:
   guard usable(kind) else { return violation("heartbeat before authentication") }
   guard let a = try? HeartbeatAck(f.payload) else { return violation("heartbeat ack") }
   if kind == .controlInput, let sent = pings.removeValue(forKey: a.nonce), stamp.localTime >= sent { controlRTT = stamp.localTime - sent; clockEstimate = ClockEstimate(sent: sent, peerReceived: a.receiveTime, peerSent: a.sendTime, received: stamp.localTime)
    performance?.record(PerformanceEvent("clock.exchange", time: stamp.localTime, generation: UInt64(generation), attachment: attachmentID, link: link.traceID, stream: kind.rawValue, t1: sent, t2: a.receiveTime, t3: a.sendTime, t4: stamp.localTime)) }
  case .goodbye:
   finish(.peerGoodbye((try? Goodbye(f.payload))?.reason ?? .userDisconnect))
  case .error:
   finish(.peerError((try? ErrorMessage(f.payload))?.code ?? .protocolViolation))
  case .hello, .helloAck:
   violation("unexpected handshake frame")
  default:
   guard usable(kind) else { return violation("frame before handshake") }
   guard f.generation == generation else { return violation("generation") }
   if !announcedReady {
    guard initialFrames.count < 32, initialFrameBytes + f.payload.count <= 128 * 1024 else { return violation("initial queue limit") }
    initialFrames.append((kind, f, stamp)); initialFrameBytes += f.payload.count
   } else { onEvent?(.frame(kind, f, stamp)) }
  }
 }
}

/// iPad side: accepts incoming streams, identifies them by their first HELLO, and owns at most
/// one attachment. A newer attachment from the Mac replaces the current one (Phase 1: one Mac).
public final class PadAttachmentHost {
 public private(set) var current: Attachment?
 private var candidate: Attachment?
 private let security: AttachmentSecurity?
 public var onAttachment: ((Attachment) -> Void)?
 /// Called for each rejected stream with the reason (diagnostics / UI).
 public var onReject: ((AttachmentEnd) -> Void)?
 private let local: () -> LocalIdentity, timing: AttachmentTiming, queue: DispatchQueue, clock: () -> UInt64
 private var pending: [ObjectIdentifier: (ByteStream, FrameDecoder, UInt64, TransportKind)] = [:]
 /// B HELLOs that arrived before their A. A and B are independent connections, so this order is
 /// normal; B waits (bounded, handshake timeout) and is adopted when its A arrives.
 private var parkedVideo: [(stream: ByteStream, decoder: FrameDecoder, hello: Hello, since: UInt64, transport: TransportKind)] = []

 public init(local: @escaping () -> LocalIdentity, timing: AttachmentTiming = AttachmentTiming(), security: AttachmentSecurity? = nil, queue: DispatchQueue, clock: @escaping () -> UInt64 = { MonotonicClock.now }) {
  self.security = security; self.local = local; self.timing = timing; self.queue = queue; self.clock = clock
 }

 /// Must be called on `queue`.
 public func accept(_ stream: ByteStream, transport: TransportKind = .usb) {
  guard pending.count < 4 else { stream.close(); return }
  let id = ObjectIdentifier(stream); pending[id] = (stream, FrameDecoder(connection: nil), clock(), transport)
  stream.onData = { [weak self] data in self?.queue.async { self?.pendingData(id, data) } }
  stream.onClose = { [weak self] _ in self?.queue.async { self?.pending.removeValue(forKey: id) } }
  stream.start()
 }

 /// Suspend also cancels a pairing candidate; late confirmation cannot open a background session.
 public func closeAll(_ reason: GoodbyeReason) {
  candidate?.close(reason); current?.close(reason)
  for p in parkedVideo { p.stream.close() }; parkedVideo.removeAll()
  for p in pending.values { p.0.close() }; pending.removeAll()
 }

 /// Expire unidentified streams; forward to the current attachment.
 public func tick() {
  let now = clock()
  for (id, entry) in pending where now >= entry.2 &+ timing.handshakeTimeout { pending.removeValue(forKey: id); entry.0.close(); onReject?(.handshakeTimeout) }
  let expired = parkedVideo.filter { now >= $0.since &+ timing.handshakeTimeout }
  parkedVideo.removeAll { now >= $0.since &+ timing.handshakeTimeout }
  for p in expired { reject(p.stream, .peerError(.attachmentMismatch), error: ErrorMessage(code: .attachmentMismatch, faultRow: 8, detail: "video without its control connection")) }
  current?.tick(); candidate?.tick()
 }

 private func reject(_ stream: ByteStream, _ end: AttachmentEnd, error: ErrorMessage?) {
  if let error, let data = try? Frame(type: .error, generation: 0, sequence: 1, timestamp: clock(), payload: error.encoded()).encoded() { stream.send(data) { _ in stream.close() } } else { stream.close() }
  onReject?(end)
 }

 private func pendingData(_ id: ObjectIdentifier, _ data: Data) {
  guard let entry = pending[id] else { return }
  let stream = entry.0; var decoder = entry.1
  let items: [DecodedItem]
  do { items = try decoder.feed(data) } catch { pending.removeValue(forKey: id); reject(stream, .protocolViolation(String(describing: error)), error: ErrorMessage(code: .protocolViolation, faultRow: 8, detail: "first frame")); return }
  guard let first = items.first else { pending[id]?.1 = decoder; return }
  pending.removeValue(forKey: id)
  guard items.count == 1, decoder.bufferedBytes == 0, case .frame(let f) = first, f.type == .hello else { reject(stream, .protocolViolation("first frame"), error: nil); return }
  let versions = PINK2.wireVersion...PINK2.wireVersion
  guard let range = try? Hello.versionRange(f.payload) else { reject(stream, .protocolViolation("hello"), error: nil); return }
  if case let outcome = VersionNegotiation.negotiate(local: versions, remote: range), outcome != .agreed(PINK2.wireVersion) || f.wireVersion != PINK2.wireVersion {
   reject(stream, .versionMismatch(outcome), error: ErrorMessage(code: .versionMismatch, faultRow: 8, detail: "local \(versions.lowerBound)-\(versions.upperBound)")); return
  }
  guard let h = try? Hello(f.payload), h.role == .mac, h.generation > 0 else { reject(stream, .protocolViolation("hello"), error: ErrorMessage(code: .protocolViolation, faultRow: 8, detail: "hello")); return }
  if entry.3 == .wifi, security?.store.peer(h.deviceID) == nil { reject(stream, .peerError(.authenticationFailed), error: nil); return }
  decoder.identify(h.connection)
  switch h.connection {
  case .controlInput:
   if let current, current.ended == nil, (current.peer?.deviceID != h.deviceID || (current.transport == .usb && entry.3 == .wifi)) { reject(stream, .peerError(.busy), error: ErrorMessage(code: .busy, faultRow: 8)); return }
   if let candidate, candidate.ended == nil { reject(stream, .peerError(.busy), error: ErrorMessage(code: .busy, faultRow: 8)); return }
   let a = Attachment(role: .ipad, attachmentID: h.attachmentID, generation: h.generation, resumeToken: h.resumeToken, local: local(), timing: timing, security: security, transport: entry.3, trustedOnly: entry.3 == .wifi, queue: queue, clock: clock)
   candidate = a
   a.onEvent = { [weak self, weak a] event in
    guard let self, let a, self.candidate === a else { return }
    switch event {
    case .ready:
     if let old = self.current, old.ended == nil { old.finish(.replaced) }
     self.current = a; self.candidate = nil; self.onAttachment?(a); a.onEvent?(event)
    case .ended(let end): self.candidate = nil; self.onReject?(end)
    default: break
    }
   }
   a.adopt(stream, decoder: decoder, hello: h)
   if let i = parkedVideo.firstIndex(where: { $0.hello.attachmentID == h.attachmentID }) {
    let p = parkedVideo.remove(at: i)
    if p.hello.generation == h.generation, p.hello.deviceID == h.deviceID, p.hello.resumeToken == h.resumeToken, p.transport == entry.3 { a.adopt(p.stream, decoder: p.decoder, hello: p.hello) }
    else { reject(p.stream, .peerError(.attachmentMismatch), error: ErrorMessage(code: .attachmentMismatch, faultRow: 8, detail: "video does not match its attachment")) }
   }
  case .video:
   if let a = [candidate, current].compactMap({ $0 }).first(where: { $0.ended == nil && $0.attachmentID == h.attachmentID }) {
    guard a.generation == h.generation, a.peer?.deviceID == h.deviceID, a.peer?.resumeToken == h.resumeToken, a.transport == entry.3 else { reject(stream, .peerError(.attachmentMismatch), error: ErrorMessage(code: .attachmentMismatch, faultRow: 8, detail: "video does not match its attachment")); return }
    a.adopt(stream, decoder: decoder, hello: h); return
   }
   // Possibly ahead of its own A (a new attachment, or the first one): park it, bounded.
   if parkedVideo.count >= 2 { let old = parkedVideo.removeFirst(); reject(old.stream, .peerError(.attachmentMismatch), error: nil) }
   stream.onData = { [weak self, weak stream] _ in self?.queue.async { guard let self, let stream, let i = self.parkedVideo.firstIndex(where: { $0.stream === stream }) else { return }; self.parkedVideo.remove(at: i); self.reject(stream, .protocolViolation("data before handshake"), error: nil) } }
   stream.onClose = { [weak self, weak stream] _ in self?.queue.async { self?.parkedVideo.removeAll { $0.stream === stream } } }
   parkedVideo.append((stream, decoder, h, clock(), entry.3))
  }
 }
}
