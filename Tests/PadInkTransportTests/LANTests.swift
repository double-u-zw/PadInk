import XCTest
import Network
import PadInkCore
@testable import PadInkTransport

final class LANTLSTests: XCTestCase {
 private func runConnection(wrongKey: Bool = false, plaintext: Bool = false) throws {
  let q = DispatchQueue(label: "test.lan.tls")
  let key = Data(repeating: 7, count: 32), label = "test-pair"
  let p = try LANTLS.parameters(keys: [(label,key)])
  p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
  let listener = try NWListener(using: p), ready = expectation(description: "listener")
  let result = expectation(description: "payload or rejection")
  var server: NWStream?, client: NWStream?
  let shouldReject = wrongKey || plaintext
  listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
  listener.newConnectionHandler = { connection in
   let s = NWStream(connection, queue: q); server = s; s.readyCheck = LANTLS.confirmed
   s.onData = { data in
    XCTAssertFalse(shouldReject); XCTAssertEqual(data, Data("encrypted input".utf8))
    s.send(data) { XCTAssertNil($0) }
   }; s.start()
  }
  listener.start(queue: q); wait(for: [ready], timeout: 5)
  let port = try XCTUnwrap(listener.port)
  let parameters = plaintext ? NWParameters.tcp : try LANTLS.parameters(keys: [(label, wrongKey ? Data(repeating: 8, count: 32) : key)])
  q.sync {
   let c = NWStream(NWConnection(host: "127.0.0.1", port: port, using: parameters), queue: q); client = c
   if !plaintext { c.readyCheck = LANTLS.confirmed }
   c.onData = { data in
    if plaintext { XCTAssertEqual(data.first, 21, "TLS alert, not application data"); c.onData = nil; c.onClose = nil; result.fulfill() }
    else { XCTAssertFalse(shouldReject); XCTAssertEqual(data, Data("encrypted input".utf8)); result.fulfill() }
   }
   if shouldReject { c.onClose = { _ in result.fulfill() } }
   c.start(); c.send(plaintext ? Data(repeating: 0xff, count: 512) : Data("encrypted input".utf8)) { _ in }
  }
  wait(for: [result], timeout: 5)
  q.sync { client?.onClose = nil; client?.close(); server?.close(); listener.cancel() }
 }
 func testTLS12PSKNegotiationAndEncryptedRoundTrip() throws { try runConnection() }
 func testWrongPairKeyNeverDeliversProductData() throws { try runConnection(wrongKey: true) }
 func testPlaintextNeverDeliversProductData() throws { try runConnection(plaintext: true) }
 func testInvalidKeyConfigurationFailsClosed() {
  XCTAssertThrowsError(try LANTLS.parameters(keys: []))
  XCTAssertThrowsError(try LANTLS.parameters(keys: [("key",Data(count: 31))]))
  XCTAssertThrowsError(try LANTLS.parameters(keys: (0..<33).map { ("key\($0)",Data(count: 32)) }))
 }
}

final class LANPairingSocketTests: XCTestCase {
 private final class Pipe: ByteStream {
  var onData: ((Data) -> Void)?, onClose: ((Error?) -> Void)?
  var queuedBytes = 0, closed = false
  weak var peer: Pipe?
  let q: DispatchQueue
  init(_ q: DispatchQueue) { self.q = q }
  func start() {}
  func send(_ data: Data, completion: @escaping (Error?) -> Void) {
   q.async { [self] in
    guard !closed, let peer, !peer.closed else { completion(StreamError.closed); return }
    // Fragment every packet, including its length header.
    for byte in data { peer.onData?(Data([byte])) }; completion(nil)
   }
  }
  func close() { guard !closed else { return }; closed = true; let cb = onClose; onClose = nil; cb?(nil); peer?.onClose?(nil) }
 }
 func testFragmentedExchangeFlushesFinalReceiptsBeforeClose() throws {
  let q = DispatchQueue(label: "test.pair.socket")
  // Both pipes and protocol engines use the same serial owner queue.
  let left = Pipe(q), right = Pipe(q); left.peer = right; right.peer = left
  let sa = try TrustStore(), sb = try TrustStore()
  let mac = LANPairingSocket(stream: left, identity: DeviceIdentity(), store: sa, role: .mac, name: "Mac", queue: q)
  let pad = LANPairingSocket(stream: right, identity: DeviceIdentity(), store: sb, role: .ipad, name: "iPad", queue: q)
  let finished = expectation(description: "both peers stored"); finished.expectedFulfillmentCount = 2
  var codes: [String] = []
  mac.onPrompt = { codes.append($0.code); mac.confirm(true) }; pad.onPrompt = { codes.append($0.code); pad.confirm(true) }
  mac.onComplete = { XCTAssertTrue($0); finished.fulfill() }; pad.onComplete = { XCTAssertTrue($0); finished.fulfill() }
  q.async { mac.start(); pad.start() }; wait(for: [finished], timeout: 5)
  q.sync { XCTAssertEqual(codes.count, 2); XCTAssertEqual(codes.first, codes.last); XCTAssertEqual(sa.peers.first?.pairKey, sb.peers.first?.pairKey); mac.cancel(); pad.cancel() }
 }
 func testOversizedPairingFrameFailsWithoutTrust() throws {
  let q = DispatchQueue(label: "test.pair.invalid"), stream = Pipe(DispatchQueue(label: "unused.invalid")), store = try TrustStore()
  let socket = LANPairingSocket(stream: stream, identity: DeviceIdentity(), store: store, role: .ipad, name: "iPad", queue: q)
  let done = expectation(description: "rejected")
  socket.onComplete = { XCTAssertFalse($0); done.fulfill() }
  q.async { socket.start(); stream.onData?(Data([0xff,0xff])) }
  wait(for: [done], timeout: 3); q.sync { XCTAssertTrue(store.peers.isEmpty) }
 }
}
