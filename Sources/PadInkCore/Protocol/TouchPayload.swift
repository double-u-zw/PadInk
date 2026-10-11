import Foundation

public enum TouchKind: UInt8, Codable { case pointer = 1, scroll, magnify
 public var message: MessageType { switch self { case .pointer: return .pointer; case .scroll: return .scroll; case .magnify: return .magnify } }
}
public enum TouchPhase: UInt8, Codable { case began = 1, changed, ended, cancelled }
/// 44 bytes, shared by POINTER/SCROLL/MAGNIFY. Positions and scroll deltas are normalized to the
/// displayed video rectangle; magnify dx is a logarithmic scale delta, dy is zero.
public struct TouchEvent: Equatable {
 public var gestureID: UInt64, sequence: UInt32, timestamp: UInt64, geometryGeneration: UInt32
 public var kind: TouchKind, phase: TouchPhase, clickCount: UInt8
 public var x: Float, y: Float, dx: Float, dy: Float
 public init(gestureID: UInt64, sequence: UInt32, timestamp: UInt64, geometryGeneration: UInt32, kind: TouchKind, phase: TouchPhase, clickCount: UInt8 = 1, x: Float, y: Float, dx: Float = 0, dy: Float = 0) {
  self.gestureID = gestureID; self.sequence = sequence; self.timestamp = timestamp; self.geometryGeneration = geometryGeneration
  self.kind = kind; self.phase = phase; self.clickCount = clickCount; self.x = x; self.y = y; self.dx = dx; self.dy = dy
 }
 public func validate() throws {
  guard gestureID & (1 << 63) != 0, sequence > 0, geometryGeneration > 0, [x,y,dx,dy].allSatisfy(\.isFinite), (0...1).contains(x), (0...1).contains(y), abs(dx) <= 1, abs(dy) <= 1, (1...2).contains(clickCount), phase != .began || sequence == 1 else { throw PayloadError.value }
  guard kind != .pointer || (dx == 0 && dy == 0), kind != .magnify || dy == 0 else { throw PayloadError.value }
 }
 public func encoded() throws -> Data {
  try validate(); var w = ByteWriter(); w.u64(gestureID); w.u32(sequence); w.u64(timestamp); w.u32(geometryGeneration)
  w.u8(kind.rawValue); w.u8(phase.rawValue); w.u8(clickCount); w.u8(0); w.f32(x); w.f32(y); w.f32(dx); w.f32(dy); return w.data
 }
 public init(_ data: Data, type: MessageType) throws {
  guard data.count == 44 else { throw PayloadError.length }; var r = ByteReader(data)
  gestureID = try r.u64(); sequence = try r.u32(); timestamp = try r.u64(); geometryGeneration = try r.u32()
  guard let kind = TouchKind(rawValue: try r.u8()), kind.message == type, let phase = TouchPhase(rawValue: try r.u8()) else { throw PayloadError.value }
  self.kind = kind; self.phase = phase; clickCount = try r.u8(); guard try r.u8() == 0 else { throw PayloadError.reserved }
  x = try r.f32(); y = try r.f32(); dx = try r.f32(); dy = try r.f32(); try validate()
 }
}
public struct InputSettings: Equatable {
 public var touchEnabled: Bool
 public init(touchEnabled: Bool) { self.touchEnabled = touchEnabled }
 public func encoded() -> Data { Data([touchEnabled ? 1 : 0]) }
 public init(_ data: Data) throws { guard data.count == 1, data[0] <= 1 else { throw PayloadError.value }; touchEnabled = data[0] == 1 }
}
