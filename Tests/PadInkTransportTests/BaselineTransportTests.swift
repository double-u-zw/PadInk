import XCTest
import Network
import PadInkCore
@testable import PadInkTransport

// Ported from Baseline v0.1.0 Tests/PadInkTransportTests/TransportTests.swift. SocketTests and
// USBMuxTests keep their names (SocketChannel is now FDStream; the port is 42371). The four Peer
// tests were dropped with Peer; their roles (sequence, stale session, budget, send after close) are
// covered by FrameTests and AttachmentTests in PadInkCore.

#if os(macOS)
import Darwin
final class SocketTests: XCTestCase {
 func testSocketPairPartialReadAndClose() throws {
  var fds: [Int32] = [-1, -1]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
  let channel = FDStream(fd: fds[0]); let received = expectation(description: "received"); let lock = NSLock(); var all = Data()
  channel.onData = { data in lock.lock(); all.append(data); let done = all.count == 5; lock.unlock(); if done { received.fulfill() } }
  channel.start(); try USBMux.writeAll(fds[1], Data([1, 2])); try USBMux.writeAll(fds[1], Data([3, 4, 5])); wait(for: [received], timeout: 2)
  channel.close(); Darwin.close(fds[1]); XCTAssertEqual(all, Data([1, 2, 3, 4, 5]))
 }
 func testShutdownUnblocksReaderAndWriter() throws {
  var fds: [Int32] = [-1, -1]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
  let channel = FDStream(fd: fds[0]); let closed = expectation(description: "closed"); channel.onClose = { _ in closed.fulfill() }; channel.start(); channel.close(); channel.close(); wait(for: [closed], timeout: 2); Darwin.close(fds[1])
 }
 func testSocketSendPreservesPayload() throws {
  var fds: [Int32] = [-1, -1]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0); let channel = FDStream(fd: fds[0]); channel.start(); let sent = expectation(description: "sent"); let bytes = Data((0..<255).map { UInt8($0) }); channel.send(bytes) { error in XCTAssertNil(error); sent.fulfill() }; let received = try USBMux.readExact(fds[1], 255); wait(for: [sent], timeout: 2); XCTAssertEqual(received, bytes); channel.close(); Darwin.close(fds[1])
 }
 /// 0.3: a blocked writer is visible as queued bytes (AttachmentLiveness input) and close() unblocks it.
 func testBlockedWriterReportsQueueAndCloseUnblocks() throws {
  var fds: [Int32] = [-1, -1]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
  var size: Int32 = 4096; setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
  let channel = FDStream(fd: fds[0]); channel.start(); let failed = expectation(description: "write ends")
  channel.send(Data(count: 4 << 20)) { _ in failed.fulfill() }
  Thread.sleep(forTimeInterval: 0.2)
  XCTAssertEqual(channel.queuedBytes, 4 << 20, "peer reads nothing, so the 4 MiB write is still queued")
  channel.close(); wait(for: [failed], timeout: 2); XCTAssertEqual(channel.queuedBytes, 0); Darwin.close(fds[1])
 }
}

final class USBMuxTests: XCTestCase {
 func testPlistFramingAndPartialReply() throws {
  var fds: [Int32] = [-1, -1]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0); defer { Darwin.close(fds[0]); Darwin.close(fds[1]) }
  let server = expectation(description: "server"); let remote = fds[1]
  DispatchQueue.global().async {
   defer { server.fulfill() }
   do {
    let header = try USBMux.readExact(remote, 16); let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    let payload = try USBMux.readExact(remote, Int(length) - 16); let request = try PropertyListSerialization.propertyList(from: payload, format: nil) as! [String: Any]
    XCTAssertEqual(request["MessageType"] as? String, "Connect"); XCTAssertEqual(request["PortNumber"] as? Int, Int(ProductIdentity.usbLoopbackPort.bigEndian))
    let body = try PropertyListSerialization.data(fromPropertyList: ["MessageType": "Result", "Number": 0], format: .xml, options: 0)
    var response = Data(); for word: UInt32 in [UInt32(body.count + 16), 1, 8, 1] { var le = word.littleEndian; withUnsafeBytes(of: &le) { response.append(contentsOf: $0) } }; response.append(body)
    for byte in response { try USBMux.writeAll(remote, Data([byte])) }
   } catch { XCTFail(String(describing: error)) }
  }
  let response = try USBMux.request(fds[0], ["MessageType": "Connect", "DeviceID": 42, "PortNumber": Int(ProductIdentity.usbLoopbackPort.bigEndian)])
  XCTAssertEqual(response["Number"] as? Int, 0); wait(for: [server], timeout: 3)
 }
 func testMaliciousMuxLengthRejected() throws {
  var fds: [Int32] = [-1, -1]; XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0); defer { Darwin.close(fds[0]); Darwin.close(fds[1]) }
  var data = Data(); for word: UInt32 in [0xffffffff, 1, 8, 1] { var le = word.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }; try USBMux.writeAll(fds[1], data)
  XCTAssertThrowsError(try USBMux.request(fds[0], ["MessageType": "ListDevices"]))
 }
}
#endif

/// 0.3: the full attachment over real TCP loopback sockets (what usbmuxd delivers on the iPad).
final class LoopbackAttachmentTests: XCTestCase {
 func testHandshakeAndPencilFrameOverRealLoopbackTCP() throws {
  let q = DispatchQueue(label: "test.loopback")
  let listener = try LoopbackListener(port: 0, queue: q)
  let host = PadAttachmentHost(local: { LocalIdentity(appVersion: "0.3.0", deviceID: Data(repeating: 2, count: 32), drawableWidth: 2360, drawableHeight: 1640) }, queue: q)
  let padReady = expectation(description: "pad ready"), macReady = expectation(description: "mac ready"), pencil = expectation(description: "pencil")
  host.onAttachment = { a in a.onEvent = { e in
   if case .ready = e { padReady.fulfill() }
   if case .frame(.controlInput, let f, _) = e, f.type == .pencil, let batch = try? PencilBatch(f.payload) { XCTAssertEqual(batch.samples.count, 2); pencil.fulfill() }
  } }
  listener.onStream = { host.accept($0) }
  let listening = expectation(description: "listening"); listener.onState = { if case .ready = $0 { listening.fulfill() } }
  listener.start(); wait(for: [listening], timeout: 3)
  let port = try XCTUnwrap(listener.port)
  func dial() -> NWStream { NWStream(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp), queue: q) }
  let mac = Attachment(role: .mac, attachmentID: UUID(), generation: 1, local: LocalIdentity(appVersion: "0.3.0", deviceID: Data(repeating: 1, count: 32)), queue: q)
  mac.onEvent = { e in if case .ready(let peer) = e { XCTAssertEqual(peer.drawableWidth, 2360); macReady.fulfill() } }
  q.async { mac.start(control: dial(), video: dial()) }
  wait(for: [padReady, macReady], timeout: 5)
  let samples = [PencilSample(stroke: 1, sequence: 1, timestamp: 1, x: 0.5, y: 0.5, pressure: 0.5, altitude: 1, azimuth: 0, phase: .begin), PencilSample(stroke: 1, sequence: 2, timestamp: 2, x: 0.6, y: 0.5, pressure: 0.5, altitude: 1, azimuth: 0, phase: .end)]
  q.async { host.current?.send(.pencil, payload: try! PencilBatch(samples).encoded(), on: .controlInput) }
  // iPad -> Mac direction is the product direction; verify the Mac also delivers to the iPad side.
  let back = expectation(description: "mac receives pencil")
  mac.onEvent = { e in if case .frame(.controlInput, let f, _) = e, f.type == .pencil { back.fulfill() } }
  q.async { _ = mac.send(.pencil, payload: try! PencilBatch(samples).encoded(), on: .controlInput) }
  wait(for: [back, pencil], timeout: 5)
  q.sync { mac.close(.appQuit) }; listener.cancel()
 }
}
