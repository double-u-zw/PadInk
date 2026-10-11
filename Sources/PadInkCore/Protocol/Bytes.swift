import Foundation

/// Big-endian primitives for PINK/2. Not shared with the Baseline Writer/Reader, which the
/// ported files still reference until Phase 1 moves them to these.
public struct ByteWriter {
 public private(set) var data = Data()
 public init() {}
 public mutating func u8(_ v: UInt8) { data.append(v) }
 public mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xff)]) }
 public mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xffff)) }
 public mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffff_ffff)) }
 public mutating func f32(_ v: Float) { u32(v.bitPattern) }
 public mutating func bytes(_ v: Data) { data.append(v) }
}

public enum ByteError: Error, Equatable { case truncated, trailing }

public struct ByteReader {
 private let data: Data
 public private(set) var offset = 0
 public init(_ data: Data) { self.data = Data(data) }
 public var remaining: Int { data.count - offset }
 public mutating func bytes(_ n: Int) throws -> Data {
  guard n >= 0, n <= remaining else { throw ByteError.truncated }
  defer { offset += n }; return data.subdata(in: offset..<offset + n)
 }
 public mutating func u8() throws -> UInt8 { guard remaining > 0 else { throw ByteError.truncated }; defer { offset += 1 }; return data[offset] }
 public mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
 public mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
 public mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }
 public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
 public func finish() throws { guard remaining == 0 else { throw ByteError.trailing } }
}
