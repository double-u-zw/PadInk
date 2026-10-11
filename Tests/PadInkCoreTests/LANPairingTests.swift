import XCTest
@testable import PadInkCore
final class LANPairingTests: XCTestCase {
 private final class Pair {
  let a: DeviceIdentity, b: DeviceIdentity, sa: TrustStore, sb: TrustStore, pa: LANPairing, pb: LANPairing
  var messages: [(Bool,Data)] = [], codes: [String] = [], done: [Bool] = []
  init() throws {
   a = DeviceIdentity(); b = DeviceIdentity(); sa = try TrustStore(); sb = try TrustStore()
   pa = LANPairing(identity: a, store: sa, role: .mac, name: "Mac"); pb = LANPairing(identity: b, store: sb, role: .ipad, name: "iPad")
   pa.send = { [unowned self] in messages.append((true,$0)) }; pb.send = { [unowned self] in messages.append((false,$0)) }
   pa.onPrompt = { [unowned self] in codes.append($0.code) }; pb.onPrompt = { [unowned self] in codes.append($0.code) }
   pa.onComplete = { [unowned self] in done.append($0) }; pb.onComplete = { [unowned self] in done.append($0) }
   pa.start(); pb.start()
  }
  func pump() { var limit = 20; while !messages.isEmpty, limit > 0 { limit -= 1; let m = messages.removeFirst(); (m.0 ? pb : pa).receive(m.1) }; XCTAssertGreaterThan(limit, 0) }
 }
 func testSameSASBothConsentAndSharedUSBTrustKey() throws {
  let p = try Pair(); p.pump(); XCTAssertEqual(p.codes.count, 2); XCTAssertEqual(p.codes[0], p.codes[1]); XCTAssertEqual(p.codes[0].count, 6)
  p.pa.confirm(true); p.pump(); XCTAssertTrue(p.done.isEmpty); XCTAssertTrue(p.sa.peers.isEmpty)
  p.pb.confirm(true); p.pump(); XCTAssertEqual(p.done, [true,true])
  XCTAssertEqual(p.sa.peers[0].pairKey, try p.a.pairKey(with: p.b.publicKey)); XCTAssertEqual(p.sa.peers[0].pairKey, p.sb.peers[0].pairKey)
  XCTAssertNotEqual(LANKeys.tlsKey(p.sa.peers[0].pairKey), p.sa.peers[0].pairKey)
 }
 func testRevealBeforeCommitTamperingAndRoleReflectionFail() throws {
  for scenario in 0..<3 {
   let p = try Pair()
   if scenario == 0 { p.pb.receive(Data([2]) + Data(count: 65)) }
   else if scenario == 1 { let first = p.messages.removeFirst(); p.pb.receive(first.1); var reveal = p.messages.last!.1; reveal[1] ^= 1; let second = p.messages.removeFirst(); p.pa.receive(second.1); p.pa.receive(reveal) }
   else { p.pa.receive(p.messages[0].1) }
   XCTAssertTrue(p.done.contains(false)); XCTAssertTrue(p.sa.peers.isEmpty); XCTAssertTrue(p.sb.peers.isEmpty)
  }
 }
 func testSASRejectionAndLateConsentNeverCreateTrust() throws {
  let p = try Pair(); p.pump(); p.pa.confirm(false); p.pa.confirm(true); p.pb.confirm(true); p.pump()
  XCTAssertEqual(p.done, [false]); XCTAssertTrue(p.sa.peers.isEmpty); XCTAssertTrue(p.sb.peers.isEmpty)
 }
 func testNamesResolveFullDeviceIdentityAndTLSLabelIsSymmetric() {
  let a = DeviceIdentity(), b = DeviceIdentity()
  XCTAssertEqual(LANKeys.deviceID(LANKeys.serviceName(a.id)), a.id)
  XCTAssertNil(LANKeys.deviceID("invalid")); XCTAssertEqual(LANKeys.label(local: a.id, peer: b.id), LANKeys.label(local: b.id, peer: a.id))
 }
 func testMalformedAndUnstartedPairingCannotProduceTrust() throws {
  for started in [false,true] {
   let store = try TrustStore(), p = LANPairing(identity: DeviceIdentity(), store: store, role: .mac, name: "Mac")
   var result: Bool?; p.onComplete = { result = $0 }
   if started { p.start() }; p.receive(Data()); p.confirm(true)
   XCTAssertEqual(result,false); XCTAssertTrue(store.peers.isEmpty)
  }
 }
 func testTrustLimitCannotDisableTLSService() throws {
  let store = try TrustStore(), local = DeviceIdentity()
  for _ in 0..<32 { let peer = DeviceIdentity(); try store.put(TrustedPeer(publicKey: peer.publicKey, pairKey: local.pairKey(with: peer.publicKey), name: "peer")) }
  let next = DeviceIdentity(); XCTAssertThrowsError(try store.put(TrustedPeer(publicKey: next.publicKey, pairKey: local.pairKey(with: next.publicKey), name: "extra")))
  XCTAssertEqual(store.peers.count,32); try store.put(store.peers[0]); XCTAssertEqual(store.peers.count,32)
 }
 func testWiFiAdaptationPreservesTransportBudgetOnRecovery() {
  var v = VideoAdaptation(transport: .wifi)
  XCTAssertEqual(v.profile.bitrateScale,0.35); _ = v.update(congested:true,now:0)
  XCTAssertEqual(v.update(congested:true,now:3_000_000_000)?.framesPerSecond,30)
  _ = v.update(congested:false,now:4_000_000_000)
  XCTAssertEqual(v.update(congested:false,now:14_000_000_000)?.bitrateScale,0.35)
 }
 func testUSBPriorityWaitsForIdleOrCancelsBeforeSwitch() {
  var s = TransportSelection()
  XCTAssertEqual(s.decide(current: nil, usbAvailable: false, lanAvailable: true, inputActive: false, paused: false, now: 0), .connect(.wifi))
  XCTAssertEqual(s.decide(current: .wifi, usbAvailable: true, lanAvailable: true, inputActive: true, paused: false, now: 0), .stay)
  XCTAssertEqual(s.decide(current: .wifi, usbAvailable: true, lanAvailable: true, inputActive: true, paused: false, now: 500_000_000), .cancelInputAndSwitchToUSB)
  XCTAssertEqual(s.decide(current: nil, usbAvailable: true, lanAvailable: true, inputActive: false, paused: true, now: 0), .stay)
 }
}
