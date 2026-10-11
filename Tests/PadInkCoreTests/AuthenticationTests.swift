import XCTest
@testable import PadInkCore

final class AuthenticationTests: XCTestCase {
 private func security(_ byte: UInt8, save: @escaping (Data) throws -> Void = {_ in}) throws -> AttachmentSecurity {
  AttachmentSecurity(identity: try DeviceIdentity(privateKey: Data(repeating: byte, count: 32)), store: try TrustStore(save: save))
 }
 func testIdentityReloadAndPairKeyAgreement() throws {
  let a = try security(1).identity, b = try security(2).identity
  XCTAssertEqual(try DeviceIdentity(privateKey: a.privateKey).id, a.id)
  XCTAssertEqual(try a.pairKey(with: b.publicKey), try b.pairKey(with: a.publicKey))
  XCTAssertNotEqual(a.id, b.id)
  XCTAssertThrowsError(try a.pairKey(with: Data(count: 31)))
  XCTAssertThrowsError(try a.pairKey(with: Data(count: 32)))
 }
 func testTrustPersistenceIsTransactionalAndReloadable() throws {
  enum Failure: Error { case disk }
  var stored: Data?, fail = false
  let a = try security(1, save: { if fail { throw Failure.disk }; stored = $0 }), b = try security(2)
  let peer = TrustedPeer(publicKey: b.identity.publicKey, pairKey: try a.identity.pairKey(with: b.identity.publicKey), name: "iPad")
  try a.store.put(peer)
  XCTAssertEqual(try TrustStore(data: stored).peers, [peer])
  fail = true; XCTAssertThrowsError(try a.store.remove(peer.deviceID)); XCTAssertEqual(a.store.peers, [peer])
  fail = false; try a.store.remove(peer.deviceID); XCTAssertEqual(try TrustStore(data: stored).peers, [])
  XCTAssertThrowsError(try TrustStore(data: JSONEncoder().encode([peer, peer])))
 }
 private final class Exchange {
  var messages: [(Bool, MessageType, Data)] = []
  var aResult: Bool?, bResult: Bool?
  var a: AttachmentAuthentication!, b: AttachmentAuthentication!
  init(_ ac: AttachmentSecurity, _ bc: AttachmentSecurity, kind: ConnectionKind = .controlInput) {
   let id = UUID()
   let ah = Hello(connection: kind, role: .mac, appVersion: "0.3", deviceID: ac.identity.id, attachmentID: id, generation: 1, displayName: "Mac")
   let bh = Hello(connection: kind, role: .ipad, appVersion: "0.3", deviceID: bc.identity.id, attachmentID: id, generation: 1, displayName: "iPad")
   a = AttachmentAuthentication(context: ac, local: ah, peer: bh, send: { [unowned self] in messages.append((true, $0, $1)) }, complete: { [unowned self] in aResult = $0 })
   b = AttachmentAuthentication(context: bc, local: bh, peer: ah, send: { [unowned self] in messages.append((false, $0, $1)) }, complete: { [unowned self] in bResult = $0 })
   a.start(); b.start()
  }
  func pump() { var limit = 100; while !messages.isEmpty && limit > 0 { limit -= 1; let m = messages.removeFirst(); (m.0 ? b : a)?.receive(m.1, m.2) }; XCTAssertGreaterThan(limit, 0) }
 }
 func testBothConfirmationsRequiredAndReconnectUsesStoredTrust() throws {
  let a = try security(1), b = try security(2), x = Exchange(a, b)
  x.pump(); XCTAssertNil(x.aResult); XCTAssertNil(x.bResult)
  XCTAssertEqual(a.requests.count, 1); XCTAssertEqual(b.requests.count, 1)
  a.confirm(b.identity.id, accepted: true); x.pump(); XCTAssertNil(x.aResult); XCTAssertNil(x.bResult)
  b.confirm(a.identity.id, accepted: true); x.pump(); XCTAssertEqual(x.aResult, true); XCTAssertEqual(x.bResult, true)
  XCTAssertEqual(a.store.peers.count, 1); XCTAssertEqual(b.store.peers.count, 1)
  let y = Exchange(a, b); y.pump(); XCTAssertEqual(y.aResult, true); XCTAssertEqual(y.bResult, true); XCTAssertTrue(a.requests.isEmpty)
 }
 func testModifiedProofAndFreshChallengeRejectReplay() throws {
  let a = try security(1), b = try security(2), x = Exchange(a, b)
  x.pump(); a.confirm(b.identity.id, accepted: true)
  let oldProof = try XCTUnwrap(x.messages.first?.2)
  b.confirm(a.identity.id, accepted: true); x.pump(); XCTAssertEqual(x.aResult, true)
  let y = Exchange(a, b)
  // Deliver only new offers, then substitute an old proof: transcript includes fresh nonces.
  for _ in 0..<2 { let m = y.messages.removeFirst(); (m.0 ? y.b : y.a)?.receive(m.1, m.2) }
  y.b.receive(.authProof, oldProof); XCTAssertEqual(y.bResult, false)
  let z = Exchange(a, b); for _ in 0..<2 { let m = z.messages.removeFirst(); (m.0 ? z.b : z.a)?.receive(m.1, m.2) }
  var modified = try XCTUnwrap(z.messages.first?.2); modified[1] ^= 1
  z.b.receive(.authProof, modified); XCTAssertEqual(z.bResult, false)
 }
 func testWrongIdentityRejectedBeforeConfirmation() throws {
  let a = try security(1), b = try security(2), x = Exchange(a, b)
  var offer = x.messages[0].2; offer[1] ^= 1
  x.b.receive(.authProof, offer); XCTAssertEqual(x.bResult, false); XCTAssertTrue(b.requests.isEmpty)
 }
 func testCancelAndRejectCannotBeRevivedByLateConfirmation() throws {
  let a = try security(1), b = try security(2), x = Exchange(a, b)
  x.pump(); x.a.cancel(); a.confirm(b.identity.id, accepted: true)
  b.confirm(a.identity.id, accepted: false); x.pump()
  XCTAssertNil(x.aResult); XCTAssertEqual(x.bResult, false); XCTAssertTrue(a.store.peers.isEmpty)
 }
 func testFailedKeychainWriteDoesNotReleaseConnection() throws {
  enum Failure: Error { case keychain }
  let a = try security(1, save: {_ in throw Failure.keychain}), b = try security(2), x = Exchange(a, b)
  x.pump(); a.confirm(b.identity.id, accepted: true); b.confirm(a.identity.id, accepted: true); x.pump()
  XCTAssertEqual(x.aResult, false); XCTAssertNil(x.bResult); XCTAssertTrue(a.store.peers.isEmpty)
 }
 func testTrustedVideoReauthenticationDoesNotRewriteKeychain() throws {
  enum Failure: Error { case keychainUnavailable }
  var unavailable = false, writes = 0
  let a = try security(1, save: { _ in if unavailable { throw Failure.keychainUnavailable }; writes += 1 }), b = try security(2)
  let first = Exchange(a,b); first.pump(); a.confirm(b.identity.id, accepted:true); b.confirm(a.identity.id,accepted:true); first.pump()
  XCTAssertEqual(first.aResult,true); XCTAssertEqual(writes,1)
  unavailable = true
  let replacement = Exchange(a,b,kind:.video); replacement.pump()
  XCTAssertEqual(replacement.aResult,true); XCTAssertEqual(replacement.bResult,true); XCTAssertEqual(writes,1)
 }
 func testForgetBlocksAutomaticReconnectUntilUserRequestsPairing() throws {
  let a = try security(1), b = try security(2), x = Exchange(a, b)
  x.pump(); a.confirm(b.identity.id, accepted: true); b.confirm(a.identity.id, accepted: true); x.pump()
  try a.forget(b.identity.id); let y = Exchange(a, b); y.pump(); XCTAssertEqual(y.aResult, false)
  a.allowNewPairing(); let z = Exchange(a, b); z.pump(); XCTAssertEqual(a.requests.count, 1); XCTAssertNil(z.aResult)
 }
}

final class SecureAttachmentTests: XCTestCase {
 private let q = DispatchQueue(label: "test.secureAttachment")
 private var streams: [FakeStream] = []
 private var now: UInt64 = 1_000_000_000
 private func pair() -> (FakeStream, FakeStream) { let p = FakeStream.pair(label: "auth.\(streams.count)"); streams += [p.0, p.1]; return p }
 private func settle() { for _ in 0..<32 { streams.forEach { $0.settle() }; q.sync {} } }
 private func context() throws -> AttachmentSecurity { AttachmentSecurity(identity: DeviceIdentity(), store: try TrustStore()) }
 private func identity(_ c: AttachmentSecurity) -> LocalIdentity { LocalIdentity(appVersion: "0.3", deviceID: c.identity.id) }
 private func connect(_ mac: AttachmentSecurity, _ pad: AttachmentSecurity, host old: PadAttachmentHost? = nil, transport: TransportKind = .usb) -> (Attachment, PadAttachmentHost) {
  let host = old ?? PadAttachmentHost(local: { [self] in identity(pad) }, security: pad, queue: q, clock: { [self] in now })
  let a = Attachment(role: .mac, attachmentID: UUID(), generation: 1, local: identity(mac), security: mac, transport: transport, expectedPeerID: transport == .wifi ? pad.identity.id : nil, trustedOnly: transport == .wifi, queue: q, clock: { [self] in now })
  let ca = pair(), cb = pair()
  q.sync { host.accept(ca.1, transport: transport); host.accept(cb.1, transport: transport); a.start(control: ca.0, video: cb.0) }; settle()
  return (a, host)
 }
 private func approve(_ a: AttachmentSecurity, _ b: AttachmentSecurity) { q.sync { a.confirm(b.identity.id, accepted: true); b.confirm(a.identity.id, accepted: true) }; settle() }
 private func trust(_ a: AttachmentSecurity, _ b: AttachmentSecurity) throws {
  try a.store.put(TrustedPeer(publicKey: b.identity.publicKey, pairKey: a.identity.pairKey(with: b.identity.publicKey), name: "iPad"))
  try b.store.put(TrustedPeer(publicKey: a.identity.publicKey, pairKey: b.identity.pairKey(with: a.identity.publicKey), name: "Mac"))
 }
 func testUnknownLANPeerCannotPromptOrCreateProductSession() throws {
  let a = try context(), b = try context(), (mac, host) = connect(a, b, transport: .wifi)
  XCTAssertFalse(mac.isReady); XCTAssertNil(host.current); XCTAssertTrue(a.requests.isEmpty); XCTAssertTrue(b.requests.isEmpty)
 }
 func testUSBTrustIsReusedOverLANAndUSBReplacesWiFi() throws {
  let a = try context(), b = try context(); try trust(a,b)
  let (wifi,host) = connect(a,b,transport: .wifi); XCTAssertTrue(wifi.isReady); XCTAssertEqual(host.current?.transport, .wifi)
  let (usb,_) = connect(a,b,host:host); XCTAssertTrue(usb.isReady); XCTAssertNotNil(wifi.ended); XCTAssertEqual(host.current?.transport, .usb)
  let (intruder,_) = connect(a,b,host:host,transport: .wifi)
  XCTAssertFalse(intruder.isReady); XCTAssertTrue(usb.isReady); XCTAssertEqual(host.current?.transport,.usb)
 }
 func testDifferentTrustedMacCannotDisplaceActiveMac() throws {
  let a = try context(), b = try context(), stranger = try context(); try trust(a,b); try trust(stranger,b)
  let (mac,host) = connect(a,b,transport:.wifi), old = host.current
  let (other,_) = connect(stranger,b,host:host)
  XCTAssertFalse(other.isReady); XCTAssertTrue(mac.isReady); XCTAssertTrue(host.current === old)
 }
 func testNoApplicationTrafficUntilBothSidesConfirmAndOnlyOnePromptForAB() throws {
  let a = try context(), b = try context(), (mac, host) = connect(a, b)
  XCTAssertEqual(a.requests.count, 1); XCTAssertEqual(b.requests.count, 1); XCTAssertNil(host.current)
  XCTAssertFalse(q.sync { mac.send(.keyframeRequest, on: .video) }); XCTAssertFalse(mac.isReady)
  approve(a, b); XCTAssertTrue(mac.isReady); XCTAssertTrue(host.current?.isReady == true)
 }
 func testControlProductFrameWaitsForOtherLinksAuthentication() throws {
  let a = try context(), b = try context(), (mac, host) = connect(a, b)
  streams[2].stall(); approve(a, b)
  var delivered: [Frame] = []; mac.onEvent = { if case .frame(_, let f, _) = $0 { delivered.append(f) } }
  streams[1].send(try Frame(type: .inputSettings, generation: 1, sequence: 5, timestamp: 0, payload: InputSettings(touchEnabled: true).encoded()).encoded()) { _ in }; settle()
  XCTAssertNil(mac.ended); XCTAssertTrue(delivered.isEmpty)
  streams[2].resume(); settle()
  XCTAssertTrue(mac.isReady); XCTAssertNotNil(host.current); XCTAssertEqual(delivered.map(\.type), [.inputSettings])
 }
 func testPairingTimeoutAndLateUIAnswerNeverReviveAttachment() throws {
  let a = try context(), b = try context(), (mac, host) = connect(a, b)
  now += 120_000_000_000; q.sync { mac.tick(); host.tick() }; settle()
  XCTAssertEqual(mac.ended, .handshakeTimeout); XCTAssertTrue(a.requests.isEmpty)
  approve(a, b); XCTAssertFalse(mac.isReady); XCTAssertNil(host.current)
 }
 func testUnauthenticatedNewAttachmentCannotReplaceActiveSession() throws {
  let a = try context(), b = try context(), (mac, host) = connect(a, b)
  approve(a, b); let old = try XCTUnwrap(host.current)
  let stranger = try context(), (other, _) = connect(stranger, b, host: host)
  XCTAssertTrue(host.current === old); XCTAssertNil(old.ended); XCTAssertTrue(mac.isReady)
  q.sync { b.confirm(stranger.identity.id, accepted: false) }; settle()
  XCTAssertNotNil(other.ended); XCTAssertNil(old.ended); XCTAssertTrue(host.current === old)
 }
 func testVideoReplacementAuthenticatesWithoutPromptAndPreservesA() throws {
  let a = try context(), b = try context(), (mac, host) = connect(a, b); approve(a, b)
  let old = host.current, p = pair()
  q.sync { host.accept(p.1); mac.replaceVideo(p.0) }; settle()
  XCTAssertTrue(mac.isReady); XCTAssertTrue(host.current === old); XCTAssertNil(old?.ended); XCTAssertTrue(a.requests.isEmpty)
 }
 func testUnprovedReplacementVideoCannotKillCurrentSession() throws {
  let a = try context(), b = try context(), (mac, host) = connect(a, b); approve(a, b)
  let old = host.current, p = pair()
  let hello = Hello(connection: .video, role: .mac, appVersion: "0.3", deviceID: a.identity.id, attachmentID: mac.attachmentID, generation: 1)
  q.sync { host.accept(p.1) }
  p.0.send(try Frame(type: .hello, generation: 0, sequence: 1, timestamp: 0, payload: hello.encoded()).encoded()) {_ in}; settle()
  p.0.send(try Frame(type: .authProof, generation: 1, sequence: 2, timestamp: 0, payload: Data(repeating: 0, count: 65)).encoded() + Frame(type: .goodbye, generation: 1, sequence: 3, timestamp: 0, payload: Goodbye(reason: .userDisconnect).encoded()).encoded()) {_ in}; settle()
  XCTAssertTrue(host.current === old); XCTAssertNil(old?.ended); XCTAssertTrue(mac.isReady); XCTAssertTrue(p.1.isClosed)
 }
}
