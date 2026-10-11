import XCTest
@testable import PadInkCore

final class PencilPayloadTests: XCTestCase {
 private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
 private func data(_ hex: String) -> Data { Data(stride(from: 0, to: hex.count, by: 2).map { i in UInt8(hex.dropFirst(i).prefix(2), radix: 16)! }) }
 private let begin = PencilWireSample(sequence: 1, timestamp: 1000, x: 0.5, y: 0.25, pressure: 1, altitude: 0, azimuth: 0, phase: .began)
 private let end = PencilWireSample(sequence: 2, timestamp: 2000, x: 0.75, y: 0.5, pressure: 0.5, altitude: 1, azimuth: -1, phase: .ended, estimated: true)
 private var batch: PencilBatch { PencilBatch(gestureID: 0x102, geometryGeneration: 7, samples: [begin, end]) }

 // Header 20 B: gestureID u64 | geometryGeneration u32 | batchFlags u8 | reserved u8, u16 | count u16 | reserved u16
 // Sample 36 B: seq u32 | timestamp u64 | x y pressure altitude azimuth f32 | phase u8 | flags u8 | reserved u16
 private let golden =
  "0000000000000102" + "00000007" + "03" + "00" + "0000" + "0002" + "0000" +
  "00000001" + "00000000000003e8" + "3f000000" + "3e800000" + "3f800000" + "00000000" + "00000000" + "01" + "00" + "0000" +
  "00000002" + "00000000000007d0" + "3f400000" + "3f000000" + "3f000000" + "3f800000" + "bf800000" + "03" + "01" + "0000"

 func testGoldenFullPayload() throws {
  XCTAssertEqual(hex(try batch.encoded()), golden)
  XCTAssertEqual(try PencilBatch(data(golden)), batch)
 }

 func testGoldenInsideFrame() throws {
  let frame = Frame(type: .pencil, generation: 3, sequence: 1, timestamp: 0, payload: try batch.encoded())
  let bytes = try frame.encoded()
  XCTAssertEqual(hex(bytes.prefix(PINK2.headerSize)), "504e4b32" + "0003" + "0101" + "0001" + "0000" + "00000003" + "0000000000000001" + "0000000000000000" + "0000005c")  // 20 + 2 × 36 = 92
  var d = FrameDecoder(connection: .controlInput)
  guard case .frame(let f) = try d.feed(bytes).first else { return XCTFail() }
  XCTAssertEqual(try PencilBatch(f.payload), batch)
 }

 func testSizesAreDerivedFromLayoutAndRegistry() throws {
  XCTAssertEqual(PencilBatch.headerSize, 20); XCTAssertEqual(PencilBatch.sampleSize, 36)
  XCTAssertEqual(try PencilBatch(gestureID: 1, geometryGeneration: 1, samples: [begin]).encoded().count, 20 + 36)
  let full = (1...256).map { PencilWireSample(sequence: UInt32($0), timestamp: UInt64($0), x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0, phase: $0 == 1 ? .began : .changed) }
  XCTAssertEqual(try PencilBatch(gestureID: 1, geometryGeneration: 1, samples: full).encoded().count, PencilBatch.maxPayload)
  XCTAssertEqual(PencilBatch.maxPayload, 9236)
  XCTAssertEqual(MessageRegistry.spec(.pencil)?.maxPayload, PencilBatch.maxPayload)
  XCTAssertThrowsError(try PencilBatch(gestureID: 1, geometryGeneration: 1, samples: full + [full[1]]).encoded()) { XCTAssertEqual($0 as? PencilPayloadError, .count) }
 }

 private func mutate(_ offset: Int, _ byte: UInt8) -> Data { var d = data(golden); d[offset] = byte; return d }

 func testMalformedPayloadsAreRejectedWhole() {
  let cases: [(Data, PencilPayloadError)] = [
   (data(golden).prefix(19), .length),
   (data(golden).dropLast(), .length),
   (data(golden) + Data([0]), .length),
   (mutate(17, 0), .count),                    // count (bytes 16–17) -> 0
   (mutate(17, 1), .length),                   // count 1 but two samples present
   (mutate(13, 1), .reserved),                 // reserved u8
   (mutate(14, 1), .reserved),                 // reserved u16
   (mutate(18, 1), .reserved),                 // trailing header reserved
   (mutate(16, 1), .count),                    // count 258 > 256
   (mutate(12, 1), .flags),                    // batchFlags disagrees with phases
   (mutate(20 + 36 + 33, 2), .flags),          // unknown sample flag bit
   (mutate(20 + 34, 1), .reserved),            // sample reserved
   (mutate(20 + 32, 9), .phase),               // unknown phase
   (mutate(20 + 32, 2), .flags),               // first sample no longer "began" -> flags mismatch after validation passes
   (mutate(20 + 36 + 3, 3), .order),           // sequence gap
   (mutate(20 + 36 + 10, 0), .order),          // timestamp regresses below 1000
   (mutate(20 + 12, 0x7f), .value),            // x = NaN-ish exponent -> out of range / not finite
   (mutate(7, 0), .identity),                  // gestureID 0x100 -> still >0, so zero it fully below
  ]
  for (i, (payload, expected)) in cases.enumerated() where i != cases.count - 1 {
   XCTAssertThrowsError(try PencilBatch(payload), "case \(i)") { XCTAssertEqual($0 as? PencilPayloadError, expected, "case \(i)") }
  }
  var zeroID = data(golden); for i in 0..<8 { zeroID[i] = 0 }
  XCTAssertThrowsError(try PencilBatch(zeroID)) { XCTAssertEqual($0 as? PencilPayloadError, .identity) }
 }

 func testPhasePlacementRules() {
  let move = PencilWireSample(sequence: 2, timestamp: 1, x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0, phase: .changed)
  var lateBegin = begin; lateBegin.sequence = 2
  XCTAssertThrowsError(try PencilBatch(gestureID: 1, geometryGeneration: 1, samples: [lateBegin]).encoded())
  var earlyEnd = end; earlyEnd.sequence = 1
  var after = move; after.sequence = 2; after.timestamp = 3000
  XCTAssertThrowsError(try PencilBatch(gestureID: 1, geometryGeneration: 1, samples: [earlyEnd, after]).encoded()) { XCTAssertEqual($0 as? PencilPayloadError, .phase) }
  // A middle batch (no began, no terminal) is valid and has flags 0.
  var m1 = move; m1.sequence = 5; var m2 = move; m2.sequence = 6
  XCTAssertEqual(PencilBatch(gestureID: 1, geometryGeneration: 1, samples: [m1, m2]).batchFlags, 0)
  XCTAssertNoThrow(try PencilBatch(gestureID: 1, geometryGeneration: 1, samples: [m1, m2]).encoded())
  // Stationary terminal sample is kept (Baseline rule): same position/time as the previous one.
  var still = m2; still.sequence = 7; still.phase = .ended
  XCTAssertNoThrow(try PencilBatch(gestureID: 1, geometryGeneration: 1, samples: [m1, m2, still]).encoded())
 }
}
