import XCTest
@testable import PadInkCore

final class FrameTests: XCTestCase {
 private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
 private func data(_ hex: String) -> Data { Data(stride(from: 0, to: hex.count, by: 2).map { i in UInt8(hex.dropFirst(i).prefix(2), radix: 16)! }) }
 private func heartbeat(_ seq: UInt64 = 1, payload: Data = Data([0, 0, 0, 0, 0, 0, 0, 9])) -> Frame {
  Frame(type: .heartbeat, generation: 7, sequence: seq, timestamp: 0x0102_0304_0506_0708, payload: payload)
 }

 func testGoldenHeartbeatBytes() throws {
  let golden = "504e4b32" + "0003" + "0010" + "0001" + "0000" + "00000007" + "0000000000000001" + "0102030405060708" + "00000008" + "0000000000000009"
  XCTAssertEqual(hex(try heartbeat().encoded()), golden)
  var d = FrameDecoder(connection: .controlInput)
  XCTAssertEqual(try d.feed(data(golden)), [.frame(heartbeat())])
 }

 func testGoldenOptionalVideoFeedbackHasNoCriticalFlag() throws {
  let f = Frame(type: .videoFeedback, generation: 1, sequence: 1, timestamp: 0)
  XCTAssertEqual(hex(try f.encoded()), "504e4b32" + "0003" + "0204" + "0000" + "0000" + "00000001" + "0000000000000001" + "0000000000000000" + "00000000")
 }

 func testMagicDiffersFromLegacyAndLegacyPeerIsNamed() {
  XCTAssertNotEqual(PINK2.magic, PINK2.legacyMagic)
  var legacy = ByteWriter(); legacy.u32(PINK2.legacyMagic); legacy.u16(3); legacy.bytes(Data(count: 30))
  var d = FrameDecoder(connection: .controlInput)
  XCTAssertThrowsError(try d.feed(legacy.data)) { XCTAssertEqual($0 as? ProtocolError, .legacyPeer) }
 }

 func testEverySplitAndByteAtATime() throws {
  let a = try heartbeat(1).encoded(), b = try heartbeat(2, payload: Data()).encoded(), all = a + b
  for cut in 0...all.count {
   var d = FrameDecoder(connection: .video)
   let items = try d.feed(all.prefix(cut)) + d.feed(all.dropFirst(cut))
   XCTAssertEqual(items, [.frame(heartbeat(1)), .frame(heartbeat(2, payload: Data()))], "cut \(cut)")
  }
  var d = FrameDecoder(connection: .video); var items = [DecodedItem]()
  for byte in all { items += try d.feed(Data([byte])) }
  XCTAssertEqual(items.count, 2); XCTAssertEqual(d.bufferedBytes, 0)
 }

 func testOversizedPayloadRejectedBeforeBuffering() throws {
  var w = ByteWriter(); w.u32(PINK2.magic); w.u16(PINK2.wireVersion); w.u16(MessageType.heartbeat.rawValue); w.u16(PINK2.wireVersion); w.u16(0); w.u32(0); w.u64(1); w.u64(0); w.u32(17)
  var d = FrameDecoder(connection: .controlInput)
  XCTAssertThrowsError(try d.feed(w.data)) { XCTAssertEqual($0 as? ProtocolError, .payloadTooLarge(type: 0x0010, length: 17)) }
  XCTAssertLessThanOrEqual(d.bufferedBytes, PINK2.headerSize)
  XCTAssertThrowsError(try Frame(type: .heartbeat, generation: 0, sequence: 1, timestamp: 0, payload: Data(count: 17)).encoded())
 }

 private func raw(type: UInt16, flags: UInt16, seq: UInt64 = 1, version: UInt16 = PINK2.wireVersion, reserved: UInt16 = 0, payload: Data = Data()) -> Data {
  var w = ByteWriter(); w.u32(PINK2.magic); w.u16(version); w.u16(type); w.u16(flags); w.u16(reserved); w.u32(0); w.u64(seq); w.u64(0); w.u32(UInt32(payload.count)); w.bytes(payload); return w.data
 }

 func testUnknownOptionalIsReportedAndSkippedUnknownCriticalFails() throws {
  var d = FrameDecoder(connection: .controlInput)
  XCTAssertEqual(try d.feed(raw(type: 0x7777, flags: 0, payload: Data(count: 5)) + heartbeat(2).encoded()), [.ignoredUnknown(type: 0x7777, length: 5), .frame(heartbeat(2))])
  var e = FrameDecoder(connection: .controlInput)
  XCTAssertThrowsError(try e.feed(raw(type: 0x7777, flags: 1))) { XCTAssertEqual($0 as? ProtocolError, .unknownCritical(0x7777)) }
  var f = FrameDecoder(connection: .controlInput)
  XCTAssertThrowsError(try f.feed(raw(type: 0x7777, flags: 0, payload: Data(count: PINK2.unknownPayloadLimit + 1))))
 }

 func testWrongConnectionReservedFlagsAndKeyframeMisuse() {
  var a = FrameDecoder(connection: .video)
  XCTAssertThrowsError(try a.feed(raw(type: MessageType.pencil.rawValue, flags: 1))) { XCTAssertEqual($0 as? ProtocolError, .wrongConnection(type: 0x0101)) }
  var b = FrameDecoder(connection: .controlInput)
  XCTAssertThrowsError(try b.feed(raw(type: 0x0010, flags: 1, reserved: 1))) { XCTAssertEqual($0 as? ProtocolError, .reserved) }
  var c = FrameDecoder(connection: .controlInput)
  XCTAssertThrowsError(try c.feed(raw(type: 0x0010, flags: 1 | 4))) { XCTAssertEqual($0 as? ProtocolError, .flags(5)) }
  var d = FrameDecoder(connection: .controlInput)
  XCTAssertThrowsError(try d.feed(raw(type: 0x0010, flags: 1 | 2)))
  XCTAssertThrowsError(try Frame(type: .heartbeat, flags: [.critical, .keyframe], generation: 0, sequence: 1, timestamp: 0).encoded())
  XCTAssertNoThrow(try Frame(type: .videoFrame, flags: [.critical, .keyframe], generation: 1, sequence: 1, timestamp: 0).encoded())
 }

 func testUnidentifiedStreamAcceptsOnlyHelloThenIdentifies() throws {
  var d = FrameDecoder(connection: nil)
  XCTAssertThrowsError(try d.feed(heartbeat(1).encoded())) { XCTAssertEqual($0 as? ProtocolError, .wrongConnection(type: 0x0010)) }
  var e = FrameDecoder(connection: nil)
  XCTAssertThrowsError(try e.feed(raw(type: 0x7777, flags: 0))) // even optional unknown types wait for identification
  var f = FrameDecoder(connection: nil)
  XCTAssertEqual(try f.feed(raw(type: 0x0001, flags: 1)).count, 1)
  f.identify(.video)
  XCTAssertThrowsError(try f.feed(raw(type: MessageType.pencil.rawValue, flags: 1, seq: 2))) { XCTAssertEqual($0 as? ProtocolError, .wrongConnection(type: 0x0101)) }
 }

 func testSequenceMustStartAtOneAndIncrementByOne() throws {
  var d = FrameDecoder(connection: .controlInput)
  XCTAssertThrowsError(try d.feed(heartbeat(2).encoded())) { XCTAssertEqual($0 as? ProtocolError, .sequence(expected: 1, got: 2)) }
  var e = FrameDecoder(connection: .controlInput)
  _ = try e.feed(heartbeat(1).encoded())
  XCTAssertThrowsError(try e.feed(heartbeat(1).encoded())) { XCTAssertEqual($0 as? ProtocolError, .sequence(expected: 2, got: 1)) }
 }

 func testOtherVersionOnlyDeliveredForHelloSoMismatchCanBeExplained() throws {
  var d = FrameDecoder(connection: .controlInput)
  guard case .frame(let hello) = try d.feed(raw(type: 0x0001, flags: 1, version: 4, payload: Data([0, 1, 0, 2]))).first else { return XCTFail() }
  XCTAssertEqual(hello.wireVersion, 4)
  var e = FrameDecoder(connection: .controlInput)
  XCTAssertThrowsError(try e.feed(raw(type: 0x0010, flags: 1, version: 4))) { XCTAssertEqual($0 as? ProtocolError, .unsupportedVersion(4)) }
 }

 func testCriticalFlagFollowsRegistry() {
  XCTAssertThrowsError(try Frame(type: .heartbeat, flags: [], generation: 0, sequence: 1, timestamp: 0).encoded())
  XCTAssertThrowsError(try Frame(type: .status, flags: .critical, generation: 0, sequence: 1, timestamp: 0).encoded())
  XCTAssertThrowsError(try Frame(type: MessageType(rawValue: 0x7777), generation: 0, sequence: 1, timestamp: 0).encoded())
 }

 /// Bounded fuzz: arbitrary bytes in arbitrary chunks never crash and never buffer more
 /// than one header plus the largest allowed payload.
 func testRandomInputStaysBounded() {
  var rng = SystemRandomNumberGenerator()
  for round in 0..<2_000 {
   var d = FrameDecoder(connection: round.isMultiple(of: 2) ? .controlInput : .video)
   var stream = Data((0..<Int.random(in: 0...400, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
   if round.isMultiple(of: 3) { stream = (try! heartbeat().encoded()).prefix(Int.random(in: 0...44, using: &rng)) + stream }
   var cursor = 0
   while cursor < stream.count {
    let n = Int.random(in: 1...64, using: &rng), chunk = stream.subdata(in: cursor..<min(stream.count, cursor + n)); cursor += n
    do { _ = try d.feed(chunk) } catch { break }
    XCTAssertLessThanOrEqual(d.bufferedBytes, PINK2.headerSize + 8 * 1024 * 1024)
   }
  }
 }
}

final class MessageRegistryTests: XCTestCase {
 func testTypesAreUniqueAndChannelsMatchConnections() {
  XCTAssertEqual(Set(MessageRegistry.all.map(\.type)).count, MessageRegistry.all.count)
  XCTAssertEqual(Set(MessageRegistry.all.map(\.name)).count, MessageRegistry.all.count)
  for spec in MessageRegistry.all {
   switch spec.channel {
   case .input: XCTAssertEqual(spec.connections, [.controlInput], spec.name)
   case .video: XCTAssertEqual(spec.connections, [.video], spec.name)
   case .control: XCTAssertFalse(spec.connections.isEmpty)
   }
   let range = spec.type.rawValue >> 8
   XCTAssertEqual(range, spec.channel == .control ? 0 : spec.channel == .input ? 1 : 2, spec.name)
  }
 }

 /// docs/PROTOCOL.md §3 must list exactly the registry (hex, name, required, max payload).
 func testProtocolDocumentMatchesRegistry() throws {
  let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/PROTOCOL.md")
  let text = try String(contentsOf: doc, encoding: .utf8)
  var documented = Set<String>()
  for line in text.split(separator: "\n") where line.hasPrefix("| 0x") {
   let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
   documented.insert("\(cells[0]) \(cells[1]) \(cells[3]) \(cells[4])")
  }
  let expected = Set(MessageRegistry.all.map { String(format: "0x%04X", $0.type.rawValue) + " \($0.name) \($0.required ? "required" : "optional") \($0.maxPayload)" })
  XCTAssertEqual(documented, expected)
 }
}
