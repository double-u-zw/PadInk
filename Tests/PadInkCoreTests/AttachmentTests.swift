import XCTest
@testable import PadInkCore

/// End-to-end attachment behaviour through in-memory streams with a controlled clock.
/// Fault rows refer to docs/ARCHITECTURE.md §5.
final class AttachmentTests: XCTestCase {
 private final class Box { var now: UInt64 = 1_000_000_000; var mac = [AttachmentEvent](), pad = [AttachmentEvent](), padAttachments = [Attachment](), rejects = [AttachmentEnd]() }
 private let q = DispatchQueue(label: "test.attachment")
 private var box = Box()
 private var streams = [FakeStream]()
 private let ms: UInt64 = 1_000_000

 private func identity(_ name: String, expiry: UInt64 = 0, drawable: (UInt32, UInt32) = (0, 0)) -> LocalIdentity {
  LocalIdentity(appVersion: "0.3.0", deviceID: Data(repeating: name == "mac" ? 1 : 2, count: 32), displayName: name, capabilities: name == "pad" ? [.pencilPressure] : [], signingExpiry: expiry, drawableWidth: drawable.0, drawableHeight: drawable.1)
 }
 private func settle() { for _ in 0..<8 { streams.forEach { $0.settle() }; q.sync {} } }
 private func advance(_ milliseconds: UInt64, tick: [() -> Void]) {
  var left = milliseconds
  while left > 0 { let step = min(left, 250); box.now += step * ms; left -= step; q.sync { tick.forEach { $0() } }; settle() }
 }
 private func pair() -> (FakeStream, FakeStream) { let p = FakeStream.pair(label: "fake.\(streams.count)"); streams += [p.0, p.1]; return p }

 private struct World { let mac: Attachment; let host: PadAttachmentHost; let a: (FakeStream, FakeStream); var b: (FakeStream, FakeStream) }

 private func connect(generation: UInt32 = 1, id: UUID = UUID(), host existing: PadAttachmentHost? = nil) -> World {
  let box = self.box, clock = { box.now }
  let host = existing ?? PadAttachmentHost(local: { [unowned self] in self.identity("pad", expiry: 1_790_000_000, drawable: (2360, 1640)) }, queue: q, clock: clock)
  if existing == nil {
   host.onAttachment = { a in box.padAttachments.append(a); a.onEvent = { box.pad.append($0) } }
   host.onReject = { box.rejects.append($0) }
  }
  let mac = Attachment(role: .mac, attachmentID: id, generation: generation, local: identity("mac"), queue: q, clock: clock)
  mac.onEvent = { box.mac.append($0) }
  let a = pair(), b = pair()
  q.sync { host.accept(a.1); host.accept(b.1); mac.start(control: a.0, video: b.0) }
  settle()
  return World(mac: mac, host: host, a: a, b: b)
 }
 private func ticks(_ w: World) -> [() -> Void] { [{ w.mac.tick() }, { w.host.tick() }] }
 private func ended(_ events: [AttachmentEvent]) -> AttachmentEnd? { for e in events { if case .ended(let end) = e { return end } }; return nil }
 private func inputFrames(_ events: [AttachmentEvent]) -> [Frame] { events.compactMap { if case .frame(.controlInput, let f, _) = $0 { return f }; return nil } }
 private func keepalive(_ id: UInt64) -> Data { GestureKeepalive(gestureID: id, lastSampleSequence: 1).encoded() }

 func testPerformanceWireStagesCorrelateWithoutTreatingWriteAsPeerReceipt() throws {
  let w = connect(), recorder = PerformanceRecorder(enabled: true)
  q.sync { w.mac.performance = recorder; w.mac.recordPerformanceRoutes() }
  q.sync { _ = w.mac.send(.gestureKeepalive, payload: keepalive(1), on: .controlInput) }
  settle()
  #if DEBUG
  let events = try XCTUnwrap(recorder.report()).events
  XCTAssertEqual(events.filter { $0.stage == "route.active" }.count, 2)
  let sent = try XCTUnwrap(events.first { $0.stage == "wire.send" })
  let done = try XCTUnwrap(events.first { $0.stage == "wire.writeComplete" })
  XCTAssertEqual(sent.attachment, w.mac.attachmentID); XCTAssertEqual(done.frame, sent.frame)
  XCTAssertEqual(done.link, sent.link); XCTAssertEqual(done.stream, ConnectionKind.controlInput.rawValue)
  XCTAssertEqual(done.code, "ok")
  #endif
 }

 /// Found while fixing review P1 #5: B's HELLO may arrive before A's (independent connections).
 /// The iPad must wait for A instead of rejecting B.
 func testVideoHelloArrivingBeforeControlIsAdopted() {
  let box = self.box, clock = { box.now }
  let host = PadAttachmentHost(local: { [unowned self] in self.identity("pad") }, queue: q, clock: clock)
  host.onAttachment = { a in box.padAttachments.append(a); a.onEvent = { box.pad.append($0) } }
  host.onReject = { box.rejects.append($0) }
  let mac = Attachment(role: .mac, attachmentID: UUID(), generation: 1, local: identity("mac"), queue: q, clock: clock)
  mac.onEvent = { box.mac.append($0) }
  let a = pair(), b = pair()
  a.0.stall()
  q.sync { host.accept(a.1); host.accept(b.1); mac.start(control: a.0, video: b.0) }; settle()
  XCTAssertTrue(box.mac.isEmpty, "B is parked, A not yet there"); XCTAssertEqual(box.rejects, [])
  a.0.resume(); settle()
  guard case .ready? = box.mac.first, case .ready? = box.pad.first else { return XCTFail("mac \(box.mac) pad \(box.pad)") }
  XCTAssertEqual(box.rejects, [])
 }

 func testHandshakeExchangesIdentityAndMeasuresRTTOnControlOnly() {
  let w = connect()
  guard case .ready(let peer)? = box.mac.first else { return XCTFail("mac not ready: \(box.mac)") }
  XCTAssertEqual(peer.role, .ipad); XCTAssertEqual(peer.signingExpiry, 1_790_000_000); XCTAssertEqual(peer.drawableWidth, 2360); XCTAssertEqual(peer.capabilities, [.pencilPressure])
  guard case .ready(let macPeer)? = box.pad.first else { return XCTFail("pad not ready: \(box.pad)") }
  XCTAssertEqual(macPeer.role, .mac); XCTAssertEqual(macPeer.attachmentID, w.mac.attachmentID)
  XCTAssertNil(w.mac.controlRTT)
  q.sync { w.mac.tick() }; settle()
  XCTAssertEqual(w.mac.controlRTT, 0) // fake streams deliver without delay, clock did not move
 }

 func testFaultRow3_UncertainClockDoesNotGateInput() {
  let w = connect(); w.a.1.stall()
  q.sync { w.mac.tick() }; settle(); box.now += 160 * ms
  w.a.1.resume(); settle()
  XCTAssertEqual(w.mac.clockEstimate?.reliable, false)
  let pad = box.padAttachments[0]
  q.sync { _ = pad.send(.gestureKeepalive, payload: keepalive(5), on: .controlInput) }; settle()
  XCTAssertEqual(inputFrames(box.mac).last?.type, .gestureKeepalive); XCTAssertNil(w.mac.ended)
 }

 func testInputFramesAreStampedWithLocalReceiveTime() {
  let w = connect()
  let pad = box.padAttachments[0]
  box.now += 7 * ms
  q.sync { _ = pad.send(.gestureKeepalive, payload: keepalive(5), on: .controlInput) }; settle()
  guard case .frame(.controlInput, let f, let stamp)? = box.mac.last else { return XCTFail() }
  XCTAssertEqual(f.type, .gestureKeepalive); XCTAssertEqual(stamp.localTime, box.now); XCTAssertEqual(f.generation, w.mac.generation)
 }

 /// Review of 71bdd94, P1 #2: bytes that arrive while the attachment/input queue is busy keep their
 /// arrival time; the 500 ms they wait inside PadInk is visible to the freshness check.
 func testReceiveStampIsTakenBeforeQueueBacklog() throws {
  let w = connect()
  let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
  q.async { entered.signal(); resume.wait() }; entered.wait()
  let arrived = box.now
  let bytes = try Frame(type: .gestureKeepalive, generation: 1, sequence: 2, timestamp: 0, payload: keepalive(1)).encoded()
  w.a.0.onData?(bytes)
  box.now += 500 * ms
  resume.signal(); q.sync {}
  guard case .frame(.controlInput, _, let stamp)? = box.mac.last else { return XCTFail("\(box.mac)") }
  XCTAssertEqual(stamp.localTime, arrived)
  var g = GestureFreshness(gestureID: 1, began: stamp)
  XCTAssertEqual(g.verdict(for: stamp, now: box.now, policy: .initial), .stale(age: 500 * ms))
 }

 /// Fault row 1, integration: Mac video sends stall for 5 s while A heartbeats flow. Congested,
 /// never ended, and Pencil-side traffic on A keeps arriving.
 func testFaultRow1_VideoBacklogDegradesButNeverEndsOrBlocksInput() {
  let w = connect(); let pad = box.padAttachments[0]
  w.b.0.stall()
  q.sync { for _ in 0..<20 { _ = w.mac.send(.videoFrame, payload: Data(count: 100_000), flags: [.critical], on: .video) } }
  advance(5000, tick: ticks(w))
  XCTAssertEqual(w.mac.health, .videoCongested)
  XCTAssertNil(ended(box.mac)); XCTAssertNil(ended(box.pad))
  q.sync { _ = pad.send(.gestureKeepalive, payload: keepalive(9), on: .controlInput) }; settle()
  XCTAssertEqual(inputFrames(box.mac).last?.type, .gestureKeepalive)
 }

 /// Fault row 7b: B stalled past the stall limit -> rebuild B only; input continues throughout.
 func testFaultRow7b_StalledVideoIsRebuiltWithoutTouchingInput() {
  var w = connect(); let pad = box.padAttachments[0]
  w.b.0.stall()
  q.sync { _ = w.mac.send(.videoFrame, payload: Data(count: 1000), flags: [.critical], on: .video) }
  advance(10_250, tick: ticks(w))
  XCTAssertTrue(box.mac.contains(.videoRebuildNeeded(.sendStalled)), "\(box.mac.suffix(3))")
  XCTAssertNil(ended(box.mac))
  q.sync { _ = pad.send(.gestureKeepalive, payload: keepalive(3), on: .controlInput) }; settle()
  XCTAssertEqual(inputFrames(box.mac).last?.type, .gestureKeepalive, "A must keep working while B is down")
  w.b = pair()
  q.sync { w.host.accept(w.b.1); w.mac.replaceVideo(w.b.0) }; settle()
  XCTAssertTrue(box.mac.contains(.videoRebuilt)); XCTAssertTrue(box.pad.contains(.videoRebuilt))
  XCTAssertTrue(pad === w.host.current); XCTAssertNil(ended(box.pad))
  advance(1000, tick: ticks(w))
  XCTAssertEqual(w.mac.health, .healthy)
  XCTAssertTrue(q.sync { w.mac.send(.videoFrame, payload: Data(count: 10), flags: [.critical], on: .video) })
 }

 private func rebuildRequests() -> Int { box.mac.filter { if case .videoRebuildNeeded = $0 { return true }; return false }.count }

 /// Review of 71bdd94, P1 #5 (the reviewer's probe): B fails and no replacement ever arrives. The Mac
 /// keeps asking with bounded backoff; A, input and the attachment stay alive for the whole 30 s.
 func testFaultRow7b_RebuildIsRetriedWithBackoffWhileNoReplacementArrives() {
  let w = connect(); let pad = box.padAttachments[0]
  w.b.0.fail("video socket error"); settle()
  advance(30_000, tick: ticks(w))
  let requests = rebuildRequests()
  XCTAssertGreaterThanOrEqual(requests, 3, "retried"); XCTAssertLessThanOrEqual(requests, 8, "bounded backoff, not a storm")
  XCTAssertNil(ended(box.mac)); XCTAssertNil(ended(box.pad))
  q.sync { _ = pad.send(.gestureKeepalive, payload: keepalive(4), on: .controlInput) }; settle()
  XCTAssertEqual(inputFrames(box.mac).last?.type, .gestureKeepalive)
 }

 /// First redial finds nothing (owner reports failure), a later one succeeds: video recovers.
 func testFaultRow7b_FailedRedialThenSuccessfulRedialRecovers() {
  var w = connect()
  w.b.0.fail("video socket error"); settle(); q.sync { w.mac.tick() }; settle()
  XCTAssertEqual(rebuildRequests(), 1)
  q.sync { w.mac.videoRebuildFailed() }
  advance(250, tick: ticks(w)); XCTAssertEqual(rebuildRequests(), 1, "waits for backoff")
  advance(500, tick: ticks(w)); XCTAssertEqual(rebuildRequests(), 2, "retried after 0.5 s")
  w.b = pair()
  q.sync { w.host.accept(w.b.1); w.mac.replaceVideo(w.b.0) }; settle()
  XCTAssertTrue(box.mac.contains(.videoRebuilt))
  advance(20_000, tick: ticks(w))
  XCTAssertEqual(rebuildRequests(), 2, "no further requests once B is back"); XCTAssertEqual(w.mac.health, .healthy)
 }

 /// A replacement whose HELLO is never acknowledged times out and is retried.
 func testFaultRow7b_UnacknowledgedReplacementTimesOut() {
  let w = connect()
  w.b.0.fail("video socket error"); settle(); q.sync { w.mac.tick() }; settle()
  let silent = pair() // the iPad side never accepts it
  q.sync { w.mac.replaceVideo(silent.0) }; settle()
  advance(6_000, tick: ticks(w))
  XCTAssertGreaterThanOrEqual(rebuildRequests(), 2); XCTAssertTrue(silent.0.isClosed); XCTAssertNil(ended(box.mac))
 }

 func testFaultRow7b_VideoConnectionFailureRequestsRebuildOnly() {
  let w = connect()
  w.b.0.fail("video socket error"); settle()
  q.sync { w.mac.tick() }; settle()
  XCTAssertTrue(box.mac.contains(.videoRebuildNeeded(.connectionFailed)))
  XCTAssertNil(ended(box.mac))
 }

 /// Fault row 7: A silent for 3 s -> attachment dead on both sides (input must be cancelled by owners).
 func testFaultRow7_ControlSilenceEndsBothSides() {
  let w = connect()
  w.a.0.stall(); w.a.1.stall()
  advance(3250, tick: ticks(w))
  XCTAssertEqual(ended(box.mac), .dead(.controlSilent)); XCTAssertEqual(ended(box.pad), .dead(.controlSilent))
  XCTAssertTrue(w.b.0.isClosed)
 }

 func testFaultRow7_ControlFailureEndsImmediately() {
  let w = connect()
  w.a.0.fail("cable pulled"); settle()
  XCTAssertEqual(ended(box.mac), .dead(.controlFailed)); XCTAssertEqual(ended(box.pad), .dead(.controlFailed))
 }

 /// Fault row 8.
 func testFaultRow8_GarbageOnControlIsProtocolViolation() {
  let w = connect()
  w.a.1.send(Data(repeating: 0xff, count: 40)) { _ in }; settle()
  guard case .protocolViolation? = ended(box.mac) else { return XCTFail("\(box.mac)") }
  XCTAssertNotNil(ended(box.pad))
 }

 func testVersionMismatchIsExplainedNotSilent() {
  let host = PadAttachmentHost(local: { [unowned self] in self.identity("pad") }, queue: q, clock: { [box] in box.now })
  host.onReject = { [box] in box.rejects.append($0) }
  let (macSide, padSide) = pair()
  q.sync { host.accept(padSide) }
  var future = Hello(minWireVersion: 4, maxWireVersion: 5, connection: .controlInput, role: .mac, appVersion: "0.9", deviceID: Data(count: 32), attachmentID: UUID(), generation: 1)
  future.displayName = "future"
  macSide.send(try! Frame(type: .hello, generation: 0, sequence: 1, timestamp: 0, payload: future.encoded(), wireVersion: 4).encoded()) { _ in }
  settle()
  XCTAssertEqual(box.rejects, [.versionMismatch(.updateThisDevice)])
  XCTAssertNil(host.current)
 }

 func testMacHandshakeTimeout() {
  let mac = Attachment(role: .mac, attachmentID: UUID(), generation: 1, local: identity("mac"), queue: q, clock: { [box] in box.now })
  mac.onEvent = { [box] in box.mac.append($0) }
  let a = pair(), b = pair()
  q.sync { mac.start(control: a.0, video: b.0) }
  advance(3000, tick: [{ mac.tick() }])
  XCTAssertEqual(ended(box.mac), .handshakeTimeout)
 }

 func testUnidentifiedStreamIsDroppedAfterTimeout() {
  let host = PadAttachmentHost(local: { [unowned self] in self.identity("pad") }, queue: q, clock: { [box] in box.now })
  host.onReject = { [box] in box.rejects.append($0) }
  let (_, padSide) = pair()
  q.sync { host.accept(padSide) }
  advance(3000, tick: [{ host.tick() }])
  XCTAssertEqual(box.rejects, [.handshakeTimeout]); XCTAssertTrue(padSide.isClosed)
 }

 func testVideoForUnknownAttachmentIsRejectedAndCurrentSurvives() {
  let w = connect()
  let stray = Attachment(role: .mac, attachmentID: UUID(), generation: 1, local: identity("mac"), queue: q, clock: { [box] in box.now })
  let a = pair(), b = pair()
  q.sync { w.host.accept(b.1); stray.start(control: a.0, video: b.0) }; settle()
  // Parked first (it could be ahead of its own A), rejected once the handshake window passes.
  XCTAssertEqual(box.rejects, [])
  advance(3000, tick: [{ w.host.tick() }])
  XCTAssertEqual(box.rejects, [.peerError(.attachmentMismatch)])
  XCTAssertNil(ended(box.pad)); XCTAssertTrue(w.host.current === box.padAttachments[0])
 }

 func testNewAttachmentReplacesOldOnIPad() {
  let first = connect(generation: 1)
  let old = box.padAttachments[0]
  let second = connect(generation: 2, host: first.host)
  XCTAssertEqual(old.ended, .replaced)
  XCTAssertTrue(second.host.current === box.padAttachments.last); XCTAssertEqual(second.host.current?.generation, 2)
 }

 func testGoodbyeEndsPeerWithReason() {
  let w = connect()
  q.sync { w.mac.close(.userDisconnect) }; settle()
  XCTAssertEqual(ended(box.mac), .closedLocally(.userDisconnect)); XCTAssertEqual(ended(box.pad), .peerGoodbye(.userDisconnect))
 }

 func testNothingIsDeliveredAfterEnd() {
  let w = connect(); let pad = box.padAttachments[0]
  q.sync { w.mac.close(nil) }; settle()
  let count = box.mac.count
  q.sync { _ = pad.send(.gestureKeepalive, payload: keepalive(1), on: .controlInput) }; settle()
  XCTAssertEqual(box.mac.count, count)
  XCTAssertFalse(q.sync { w.mac.send(.videoFrame, payload: Data([1]), flags: [.critical], on: .video) })
 }
}
