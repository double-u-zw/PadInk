import XCTest
@testable import PadInkCore

final class ControlPayloadTests: XCTestCase {
 private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
 private let attachment = UUID(uuid: (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15))
 private var hello: Hello { Hello(connection: .controlInput, role: .ipad, appVersion: "0.3", deviceID: Data(repeating: 0x11, count: 32), attachmentID: attachment, generation: 7, capabilities: [.pencilHover, .pencilPressure], signingExpiry: 0x6720_0000, displayName: "iPad", drawableWidth: 2360, drawableHeight: 1640) }

 func testGoldenHello() throws {
  let golden = "0003" + "0003" + "01" + "02" + "0000" + "03" + "302e33" + String(repeating: "11", count: 32) + "000102030405060708090a0b0c0d0e0f" +
   String(repeating: "00", count: 32) + "00000007" + "00000003" + "0000000067200000" + "04" + "69506164" + "00000938" + "00000668"
  XCTAssertEqual(hex(try hello.encoded()), golden)
  XCTAssertEqual(try Hello(try hello.encoded()), hello)
  XCTAssertLessThanOrEqual(try hello.encoded().count, MessageRegistry.spec(.hello)!.maxPayload)
 }

 func testHelloFrozenPrefixAndNegotiation() throws {
  var future = hello; future.minWireVersion = 3; future.maxWireVersion = 5
  XCTAssertEqual(try Hello.versionRange(future.encoded()), 3...5)
  // A future HELLO may append fields; the prefix stays readable.
  XCTAssertEqual(try Hello.versionRange(future.encoded() + Data([9, 9, 9])), 3...5)
  XCTAssertEqual(VersionNegotiation.negotiate(local: 1...1, remote: 1...3), .agreed(1))
  XCTAssertEqual(VersionNegotiation.negotiate(local: 1...1, remote: 3...5), .updateThisDevice)
  XCTAssertEqual(VersionNegotiation.negotiate(local: 4...4, remote: 1...2), .updatePeer)
 }

 func testHelloRejectsMalformed() throws {
  let good = try hello.encoded()
  var reserved = good; reserved[7] = 1; XCTAssertThrowsError(try Hello(reserved))
  var kind = good; kind[4] = 9; XCTAssertThrowsError(try Hello(kind))
  var role = good; role[5] = 0; XCTAssertThrowsError(try Hello(role))
  XCTAssertThrowsError(try Hello(good + Data([0])))
  XCTAssertThrowsError(try Hello(good.dropLast()))
  var badRange = good; badRange[1] = 2; badRange[3] = 1; XCTAssertThrowsError(try Hello(badRange)) // min 2 > max 1
  var shortID = hello; shortID.deviceID = Data(count: 31); XCTAssertThrowsError(try shortID.encoded())
 }

 /// Ported idea from Baseline testUnicodePeerNameTruncatesAtValidBoundary.
 func testUnicodeNamesTruncateAtValidBoundary() throws {
  let h = Hello(connection: .video, role: .mac, appVersion: String(repeating: "版本", count: 40), deviceID: Data(count: 32), attachmentID: UUID(), generation: 1, displayName: String(repeating: "设备🖊️", count: 100))
  let round = try Hello(h.encoded())
  XCTAssertLessThanOrEqual(round.displayName.utf8.count, 64); XCTAssertFalse(round.displayName.isEmpty)
  XCTAssertLessThanOrEqual(round.appVersion.utf8.count, 32); XCTAssertFalse(round.appVersion.isEmpty)
 }

 func testGoldenHeartbeatAckGoodbyeError() throws {
  XCTAssertEqual(hex(Heartbeat(nonce: 0x0102).encoded()), "0000000000000102")
  XCTAssertEqual(hex(HeartbeatAck(nonce: 1, receiveTime: 2, sendTime: 3).encoded()), "0000000000000001" + "0000000000000002" + "0000000000000003")
  XCTAssertEqual(hex(Goodbye(reason: .appBackground).encoded()), "02")
  XCTAssertEqual(hex(ErrorMessage(code: .versionMismatch, faultRow: 8, detail: "v1 vs v2").encoded()), "0001" + "08" + "00" + "08" + "7631207673207632")
  XCTAssertEqual(try ErrorMessage(ErrorMessage(code: .busy, faultRow: 0, detail: "x").encoded()), ErrorMessage(code: .busy, faultRow: 0, detail: "x"))
  XCTAssertThrowsError(try Heartbeat(Data(count: 9))); XCTAssertThrowsError(try Goodbye(Data([0]))); XCTAssertThrowsError(try Goodbye(Data([1, 1])))
 }

 func testErrorDetailIsAsciiAndBounded() throws {
  let e = ErrorMessage(code: .protocolViolation, faultRow: 8, detail: "文档.pptx /Users/x\n" + String(repeating: "a", count: 500))
  XCTAssertTrue(e.detail.unicodeScalars.allSatisfy { $0.isASCII }); XCTAssertEqual(e.detail.utf8.count, 200)
  XCTAssertLessThanOrEqual(e.encoded().count, MessageRegistry.spec(.error)!.maxPayload)
 }

 func testGoldenPresentedGeometryAndGestureMessages() throws {
  let g = PresentedGeometry(generation: 5, ready: true, orientation: 4, videoWidth: 2360, videoHeight: 1534)
  XCTAssertEqual(hex(g.encoded()), "00000005" + "01" + "04" + "0000" + "00000938" + "000005fe")
  XCTAssertEqual(try PresentedGeometry(g.encoded()), g)
  var bad = g.encoded(); bad[4] = 2; XCTAssertThrowsError(try PresentedGeometry(bad))
  XCTAssertThrowsError(try PresentedGeometry(PresentedGeometry(generation: 0, ready: false, orientation: 0, videoWidth: 0, videoHeight: 0).encoded()))
  XCTAssertEqual(hex(GestureNotice(gestureID: 3, reason: .geometryMismatch).encoded()), "0000000000000003" + "03")
  XCTAssertEqual(hex(GestureKeepalive(gestureID: 3, lastSampleSequence: 17).encoded()), "0000000000000003" + "00000011")
  XCTAssertThrowsError(try GestureNotice(Data(hex: "0000000000000003" + "0b")))
  XCTAssertThrowsError(try GestureKeepalive(GestureKeepalive(gestureID: 0, lastSampleSequence: 1).encoded()))
 }

 func testCancelReasonCodesAreFixed() {
  XCTAssertEqual(CancelReason.allCases.map(\.rawValue), Array(1...10))
  XCTAssertEqual(CancelReason.staleSample.rawValue, 4); XCTAssertEqual(CancelReason.gestureTimeout.rawValue, 2)
 }

 func testEveryPhase1PayloadFitsItsRegistryLimit() throws {
  let sizes: [(MessageType, Int)] = [(.hello, try hello.encoded().count), (.heartbeat, 8), (.heartbeatAck, 24), (.goodbye, 1), (.presentedGeometry, 16), (.inputCancel, 9), (.inputRejected, 9), (.gestureKeepalive, 12), (.keyframeRequest, 0)]
  for (type, size) in sizes { XCTAssertLessThanOrEqual(size, MessageRegistry.spec(type)!.maxPayload, "\(type)") }
 }
}

private extension Data {
 init(hex: String) { self.init(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }) }
}
