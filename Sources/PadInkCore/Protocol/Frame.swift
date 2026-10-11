import Foundation

/// PINK/2 envelope (docs/PROTOCOL.md §2). Payload codecs are added per phase; this file owns
/// only the frozen 36-byte header, bounded incremental decoding and unknown-message rules.
public enum PINK2 {
 /// "PNK2". Differs from the v0.1.0 / 0.2.0 magic "PINK" (0x50494E4B) in the second byte.
 public static let magic: UInt32 = 0x504E_4B32
 public static let legacyMagic: UInt32 = 0x5049_4E4B
 public static var wireVersion: UInt16 { 3 }
 public static let headerSize = 36
 /// Payload bound for unknown non-critical types; they are discarded, never interpreted.
 public static let unknownPayloadLimit = 16 * 1024
}

public struct FrameFlags: OptionSet, Equatable {
 public let rawValue: UInt16
 public init(rawValue: UInt16) { self.rawValue = rawValue }
 /// Receiver must understand this type; an unknown critical type is a protocol violation.
 public static let critical = FrameFlags(rawValue: 1 << 0)
 /// VIDEO_FRAME only: the access unit is an IDR.
 public static let keyframe = FrameFlags(rawValue: 1 << 1)
 public static let defined: FrameFlags = [.critical, .keyframe]
}

public struct Frame: Equatable {
 public var type: MessageType, flags: FrameFlags
 /// Logical-session generation (docs/ARCHITECTURE.md §4). 0 only before HELLO_ACK.
 public var generation: UInt32
 /// Per connection and direction, starts at 1, strictly +1.
 public var sequence: UInt64
 /// Sender monotonic nanoseconds. Diagnostics only; never used for input freshness.
 public var timestamp: UInt64
 /// Wire version found in the received header (always PINK2.wireVersion when encoding).
 public var wireVersion: UInt16
 public var payload: Data
 public init(type: MessageType, flags: FrameFlags? = nil, generation: UInt32, sequence: UInt64, timestamp: UInt64, payload: Data = Data(), wireVersion: UInt16 = PINK2.wireVersion) {
  self.type = type; self.flags = flags ?? (MessageRegistry.spec(type)?.required == true ? .critical : []); self.generation = generation
  self.sequence = sequence; self.timestamp = timestamp; self.payload = payload; self.wireVersion = wireVersion
 }

 public func encoded() throws -> Data {
  guard let spec = MessageRegistry.spec(type) else { throw ProtocolError.unknownType(type.rawValue) }
  guard payload.count <= spec.maxPayload else { throw ProtocolError.payloadTooLarge(type: type.rawValue, length: payload.count) }
  guard flags.isSubset(of: .defined), !flags.contains(.keyframe) || type == .videoFrame, flags.contains(.critical) == spec.required else { throw ProtocolError.flags(flags.rawValue) }
  var w = ByteWriter()
  w.u32(PINK2.magic); w.u16(PINK2.wireVersion); w.u16(type.rawValue); w.u16(flags.rawValue); w.u16(0)
  w.u32(generation); w.u64(sequence); w.u64(timestamp); w.u32(UInt32(payload.count)); w.bytes(payload)
  return w.data
 }
}

public enum ProtocolError: Error, Equatable {
 case badMagic(UInt32), legacyPeer, unsupportedVersion(UInt16), reserved, flags(UInt16)
 case unknownType(UInt16), unknownCritical(UInt16), wrongConnection(type: UInt16)
 case payloadTooLarge(type: UInt16, length: Int), sequence(expected: UInt64, got: UInt64)
}

/// Output of the decoder. Unknown optional messages are reported (for diagnostics), not dropped silently.
public enum DecodedItem: Equatable {
 case frame(Frame)
 case ignoredUnknown(type: UInt16, length: Int)
}

/// Incremental decoder for one connection direction. Holds at most one header plus one
/// bounded payload. The header is fully validated before any payload byte is buffered.
/// Any thrown error is fatal for the connection (protocol violation, docs/ARCHITECTURE.md §5).
public struct FrameDecoder {
 /// nil until the stream is identified: an accepting side does not know A from B before the
 /// first HELLO, so only HELLO is accepted in that state (then call `identify`).
 public private(set) var connection: ConnectionKind?
 private var buffer = Data(), header: (Frame, Int, Bool)?, expected: UInt64 = 1
 public init(connection: ConnectionKind?) { self.connection = connection }
 public mutating func identify(_ kind: ConnectionKind) { connection = kind }
 public var bufferedBytes: Int { buffer.count }

 public mutating func feed(_ chunk: Data) throws -> [DecodedItem] {
  var out = [DecodedItem](), cursor = chunk.startIndex
  while cursor < chunk.endIndex {
   let need = (header.map { $0.1 } ?? 0) + PINK2.headerSize - buffer.count
   let take = min(need, chunk.endIndex - cursor)
   buffer.append(chunk[cursor..<cursor + take]); cursor += take
   if header == nil, buffer.count == PINK2.headerSize { header = try parseHeader(buffer) }
   if let (frame, length, known) = header, buffer.count == PINK2.headerSize + length {
    var f = frame; f.payload = Data(buffer.dropFirst(PINK2.headerSize))
    out.append(known ? .frame(f) : .ignoredUnknown(type: f.type.rawValue, length: length))
    buffer.removeAll(keepingCapacity: true); header = nil
   }
  }
  return out
 }

 private mutating func parseHeader(_ h: Data) throws -> (Frame, Int, Bool) {
  var r = ByteReader(h)
  let magic = try r.u32()
  guard magic == PINK2.magic else { throw magic == PINK2.legacyMagic ? ProtocolError.legacyPeer : ProtocolError.badMagic(magic) }
  let version = try r.u16(), rawType = try r.u16(), flags = FrameFlags(rawValue: try r.u16())
  guard try r.u16() == 0 else { throw ProtocolError.reserved }
  let generation = try r.u32(), sequence = try r.u64(), timestamp = try r.u64(), length = Int(try r.u32())
  let type = MessageType(rawValue: rawType)
  // HELLO's header and payload prefix are frozen across versions so a mismatch can be explained.
  guard version == PINK2.wireVersion || type == .hello else { throw ProtocolError.unsupportedVersion(version) }
  guard flags.isSubset(of: .defined) else { throw ProtocolError.flags(flags.rawValue) }
  guard sequence == expected else { throw ProtocolError.sequence(expected: expected, got: sequence) }
  let known: Bool
  if let spec = MessageRegistry.spec(type) {
   if let connection { guard spec.connections.contains(connection) else { throw ProtocolError.wrongConnection(type: rawType) } }
   else { guard type == .hello else { throw ProtocolError.wrongConnection(type: rawType) } }
   guard length <= spec.maxPayload else { throw ProtocolError.payloadTooLarge(type: rawType, length: length) }
   guard !flags.contains(.keyframe) || type == .videoFrame else { throw ProtocolError.flags(flags.rawValue) }
   known = true
  } else {
   guard !flags.contains(.critical) else { throw ProtocolError.unknownCritical(rawType) }
   guard connection != nil else { throw ProtocolError.wrongConnection(type: rawType) }
   guard length <= PINK2.unknownPayloadLimit else { throw ProtocolError.payloadTooLarge(type: rawType, length: length) }
   known = false
  }
  expected = sequence &+ 1
  return (Frame(type: type, flags: flags, generation: generation, sequence: sequence, timestamp: timestamp, wireVersion: version), length, known)
 }
}
