import Foundation

public enum VideoError: Error, Equatable { case value }

/// VIDEO_CONFIG payload (PINK/2 §4.7). Validation is Baseline's.
public struct VideoConfig: Equatable {
 public var codec: VideoCodec = .h264, vps = Data()
 public var generation: UInt32, width: UInt32, height: UInt32, sps: Data, pps: Data
 public init(generation: UInt32, width: UInt32, height: UInt32, sps: Data, pps: Data, codec: VideoCodec = .h264, vps: Data = Data()) { self.codec = codec; self.vps = vps; self.generation = generation; self.width = width; self.height = height; self.sps = sps; self.pps = pps }
 public func encode() -> Data { var w = ByteWriter(); w.u32(generation); w.u32(width); w.u32(height); w.u16(UInt16(sps.count)); w.u16(UInt16(pps.count)); w.bytes(sps); w.bytes(pps); if codec == .hevc { w.u8(codec.rawValue); w.u16(UInt16(vps.count)); w.bytes(vps) }; return w.data }
 public init(_ data: Data) throws {
  var r = ByteReader(data); generation = try r.u32(); width = try r.u32(); height = try r.u32(); let a = Int(try r.u16()), b = Int(try r.u16()); sps = try r.bytes(a); pps = try r.bytes(b)
  if r.remaining > 0 { guard try r.u8() == VideoCodec.hevc.rawValue else { throw VideoError.value }; codec = .hevc; vps = try r.bytes(Int(try r.u16())); guard !vps.isEmpty else { throw VideoError.value } }
  try r.finish()
  guard generation > 0, width >= 2, height >= 2, width <= 8192, height <= 8192, width % 2 == 0, height % 2 == 0, a > 0, b > 0 else { throw VideoError.value }
 }
}

/// VIDEO_FRAME payload. `key` travels as the frame header's KEYFRAME flag and must match an actual IDR NAL.
public struct VideoFrame {
 public var generation: UInt32, id: UInt64, captureTime: UInt64, key: Bool, avcc: Data
 public init(generation: UInt32, id: UInt64, captureTime: UInt64, key: Bool, avcc: Data) { self.generation = generation; self.id = id; self.captureTime = captureTime; self.key = key; self.avcc = avcc }
 public func encode() -> Data { var w = ByteWriter(); w.u32(generation); w.u64(id); w.u64(captureTime); w.bytes(avcc); return w.data }
 public init(payload: Data, keyframe: Bool, codec: VideoCodec = .h264) throws {
  var r = ByteReader(payload); generation = try r.u32(); id = try r.u64(); captureTime = try r.u64(); avcc = try r.bytes(r.remaining); key = keyframe
  guard generation > 0, id > 0, !avcc.isEmpty else { throw VideoError.value }
  var n = ByteReader(avcc); var idr = false
  while n.remaining > 0 { let count = Int(try n.u32()); guard count > 0 else { throw VideoError.value }; let unit = try n.bytes(count); if codec == .h264 ? unit.first! & 31 == 5 : (unit.count >= 2 && [19, 20, 21].contains((unit.first! >> 1) & 63)) { idr = true } }
  guard !key || idr else { throw VideoError.value }
 }
}

public struct DecodeGate {
 private var generation: UInt32 = 0, last: UInt64 = 0
 private var needsIDR = true
 public init() {}
 public mutating func configure(_ g: UInt32) { generation = g; last = 0; needsIDR = true }
 public mutating func accept(_ f: VideoFrame) -> Bool {
  guard f.generation == generation, f.id > last else { return false }
  if !f.key && (needsIDR || f.id != last + 1) { needsIDR = true; return false }
  last = f.id; needsIDR = false; return true
 }
 public mutating func reset() { generation = 0; last = 0; needsIDR = true }
}

/// Drop a whole unsent GOP on overflow; reject all P frames until a fresh IDR. (Baseline)
/// In 0.3 this is the last rung of the congestion ladder (fault row 1), after skip-before-encode.
public struct GOPQueue {
 public let capacity: Int
 public private(set) var frames = [VideoFrame]()
 public private(set) var needsIDR = true
 public private(set) var resets = 0
 public init(capacity: Int = 2) { self.capacity = max(1, capacity) }
 public mutating func push(_ frame: VideoFrame) -> Bool {
  if frame.key { frames.removeAll(); needsIDR = false }
  if needsIDR { return false }
  if frames.count >= capacity { frames.removeAll(); needsIDR = true; resets += 1; return false }
  frames.append(frame); return true
 }
 public mutating func pop() -> VideoFrame? { frames.isEmpty ? nil : frames.removeFirst() }
 public mutating func reset() { frames.removeAll(); needsIDR = true }
}

public final class Latest<T> {
 private let lock = NSLock(); private var value: T?
 public private(set) var overwrites = 0
 public init() {}
 @discardableResult public func put(_ v: T) -> Bool { lock.lock(); defer { lock.unlock() }; let replaced = value != nil; if replaced { overwrites += 1 }; value = v; return replaced }
 public func putIfEmpty(_ v: T) { lock.lock(); defer { lock.unlock() }; if value == nil { value = v } }
 public func take() -> T? { lock.lock(); defer { lock.unlock() }; let v = value; value = nil; return v }
 public func clear() { _ = take() }
}

/// A finite recovery burst; reset only after presentation or replacing the video epoch.
public struct VideoKeyframeRetry {
 private var last: UInt64?
 public private(set) var attempts = 0
 public init() {}
 public mutating func takeAttempt(now: UInt64) -> Bool {
  guard attempts < 8 else { return false }
  if let last, now < last || now - last < 250_000_000 { return false }
  last = now; attempts += 1; return true
 }
}
