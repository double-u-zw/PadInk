import Foundation

/// PENCIL payload (docs/PROTOCOL.md §4.3): 20-byte batch header + count × 36-byte samples.
/// Semantics follow Baseline v0.1.0 (actual + coalesced, ordered, terminal kept); only the
/// layout is new. Decoding validates the whole batch before returning anything.
public enum PencilWirePhase: UInt8 { case began = 1, changed, ended, cancelled }

public struct PencilWireSample: Equatable {
 public var sequence: UInt32, timestamp: UInt64
 public var x: Float, y: Float, pressure: Float, altitude: Float, azimuth: Float
 public var phase: PencilWirePhase, estimated: Bool
 public init(sequence: UInt32, timestamp: UInt64, x: Float, y: Float, pressure: Float, altitude: Float, azimuth: Float, phase: PencilWirePhase, estimated: Bool = false) {
  self.sequence = sequence; self.timestamp = timestamp; self.x = x; self.y = y; self.pressure = pressure
  self.altitude = altitude; self.azimuth = azimuth; self.phase = phase; self.estimated = estimated
 }
}

public enum PencilPayloadError: Error, Equatable { case count, length, identity, reserved, value, order, phase, flags }

public struct PencilBatch: Equatable {
 public static let headerSize = 20, sampleSize = 36, maxSamples = 256
 public static let maxPayload = headerSize + maxSamples * sampleSize
 public var gestureID: UInt64, geometryGeneration: UInt32, samples: [PencilWireSample]
 public init(gestureID: UInt64, geometryGeneration: UInt32, samples: [PencilWireSample]) {
  self.gestureID = gestureID; self.geometryGeneration = geometryGeneration; self.samples = samples
 }
 /// bit0: batch starts the gesture; bit1: batch ends it (ended or cancelled). Derived, never free.
 public var batchFlags: UInt8 {
  (samples.first?.phase == .began ? 1 : 0) | (samples.last.map { $0.phase == .ended || $0.phase == .cancelled } == true ? 2 : 0)
 }

 public func validate() throws {
  guard (1...Self.maxSamples).contains(samples.count) else { throw PencilPayloadError.count }
  guard gestureID > 0, geometryGeneration > 0 else { throw PencilPayloadError.identity }
  for (i, s) in samples.enumerated() {
   guard [s.x, s.y, s.pressure, s.altitude, s.azimuth].allSatisfy(\.isFinite), (0...1).contains(s.x), (0...1).contains(s.y),
         (0...1).contains(s.pressure), (0...Float.pi / 2 + 0.001).contains(s.altitude), abs(s.azimuth) <= 2 * Float.pi + 0.001 else { throw PencilPayloadError.value }
   guard s.sequence > 0 else { throw PencilPayloadError.order }
   if i > 0 { guard s.sequence == samples[i - 1].sequence &+ 1, s.timestamp >= samples[i - 1].timestamp else { throw PencilPayloadError.order } }
   switch s.phase {
   case .began: guard i == 0, s.sequence == 1 else { throw PencilPayloadError.phase }
   case .ended, .cancelled: guard i == samples.count - 1 else { throw PencilPayloadError.phase }
   case .changed: break
   }
  }
 }

 public func encoded() throws -> Data {
  try validate()
  var w = ByteWriter()
  w.u64(gestureID); w.u32(geometryGeneration); w.u8(batchFlags); w.u8(0); w.u16(0); w.u16(UInt16(samples.count)); w.u16(0)
  for s in samples {
   w.u32(s.sequence); w.u64(s.timestamp); w.f32(s.x); w.f32(s.y); w.f32(s.pressure); w.f32(s.altitude); w.f32(s.azimuth)
   w.u8(s.phase.rawValue); w.u8(s.estimated ? 1 : 0); w.u16(0)
  }
  return w.data
 }

 public init(_ data: Data) throws {
  guard data.count >= Self.headerSize, data.count <= Self.maxPayload else { throw PencilPayloadError.length }
  var r = ByteReader(data)
  gestureID = try r.u64(); geometryGeneration = try r.u32()
  let flags = try r.u8(); guard try r.u8() == 0, try r.u16() == 0 else { throw PencilPayloadError.reserved }
  let count = Int(try r.u16()); guard try r.u16() == 0 else { throw PencilPayloadError.reserved }
  guard (1...Self.maxSamples).contains(count) else { throw PencilPayloadError.count }
  guard data.count == Self.headerSize + count * Self.sampleSize else { throw PencilPayloadError.length }
  var out = [PencilWireSample](); out.reserveCapacity(count)
  for _ in 0..<count {
   let seq = try r.u32(), ts = try r.u64(), x = try r.f32(), y = try r.f32(), p = try r.f32(), alt = try r.f32(), az = try r.f32()
   guard let phase = PencilWirePhase(rawValue: try r.u8()) else { throw PencilPayloadError.phase }
   let sampleFlags = try r.u8(); guard sampleFlags & ~1 == 0 else { throw PencilPayloadError.flags }
   guard try r.u16() == 0 else { throw PencilPayloadError.reserved }
   out.append(PencilWireSample(sequence: seq, timestamp: ts, x: x, y: y, pressure: p, altitude: alt, azimuth: az, phase: phase, estimated: sampleFlags == 1))
  }
  try r.finish()
  samples = out
  try validate()
  guard flags == batchFlags else { throw PencilPayloadError.flags }
 }
}
