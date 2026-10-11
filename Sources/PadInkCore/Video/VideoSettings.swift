import Foundation

public enum VideoCodec: UInt8, Codable, CaseIterable { case h264 = 0, hevc = 1 }
public enum VideoMode: String, CaseIterable { case legacy, standard, hd, highQuality, automatic, saved }
public enum VideoResolution: String, Codable, CaseIterable { case current, native, fourK, fiveK }
/// Explicit targets are experiments, not encoder promises. Zero keeps the original rate formula.
public struct VideoSettings: Codable, Equatable {
 public var resolution: VideoResolution
 public var codec: VideoCodec
 public var multiplier: Double
 public var megabits: Double
 public init(resolution: VideoResolution = .current, codec: VideoCodec = .h264, multiplier: Double = 1, megabits: Double = 0) {
  self.resolution = resolution; self.codec = codec; self.multiplier = multiplier; self.megabits = megabits
 }
 public static let baseline = VideoSettings()
 public static let dailyMegabits: [Double] = [8, 12, 16, 20]
 public static func daily(_ mode: VideoMode, codec: VideoCodec = .h264) -> VideoSettings {
  switch mode {
  case .legacy, .saved: return .baseline
  case .standard: return VideoSettings(resolution: .native, codec: codec, megabits: 8)
  case .hd: return VideoSettings(resolution: .native, codec: codec, megabits: 12)
  case .automatic: return VideoSettings(resolution: .native, codec: codec, megabits: 16)
  case .highQuality: return VideoSettings(resolution: .native, codec: codec, megabits: 20)
  }
 }
 public var mode: VideoMode {
  if self == .baseline { return .legacy }
  for mode in [VideoMode.standard, .hd, .automatic, .highQuality] {
   if self == Self.daily(mode, codec: codec) { return mode }
  }
  return .saved
 }
 public static let experimentMegabits: [Double] = [80, 120, 160, 200]
 public static let experimentMultipliers: [Double] = [1, 1.25, 1.5, 2]
 public var isValid: Bool { multiplier.isFinite && multiplier >= 1 && megabits.isFinite && megabits >= 0 && megabits < Double(Int32.max) / 1_000_000 && multiplier < 1000 }
 public func targetBitrate(baseline: Int, profile: VideoProfile) -> Int {
  let base = Double(baseline) * (profile.transport == .wifi ? 0.35 : 1)
  let requested = isValid ? (megabits > 0 ? megabits * 1_000_000 : base * multiplier) : base
  // On congestion return to the original safe ladder, even for a very large experimental target.
  let reduced = megabits > 0 && megabits <= 20
   ? min(base * 0.5, requested * (profile.quality == .reducedFrameRate ? 0.25 : 0.5)) : base * 0.5
  let rate = profile.quality == .full ? requested : reduced
  return Int(min(Double(Int32.max), max(1, rate)))
 }
}

/// Sent only after an output frame from a required-hardware decoder. Generation fences old acks.
public struct VideoFeedback: Equatable {
 public let generation: UInt32, width: UInt32, height: UInt32
 public let codec: VideoCodec
 public let congested: Bool
 public init(_ config: VideoConfig, congested: Bool = false) { self.congested = congested; generation = config.generation; width = config.width; height = config.height; codec = config.codec }
 public func encode() -> Data { var w = ByteWriter(); w.u32(generation); w.u32(width); w.u32(height); w.u8(codec.rawValue); w.u8(congested ? 1 : 0); return w.data }
 public init(_ data: Data) throws {
  var r = ByteReader(data); generation = try r.u32(); width = try r.u32(); height = try r.u32()
  guard let c = VideoCodec(rawValue: try r.u8()), generation > 0, width >= 2, height >= 2, width <= 8192, height <= 8192 else { throw VideoError.value }
  codec = c; let pressure = r.remaining == 0 ? 0 : try r.u8(); guard pressure <= 1 else { throw VideoError.value }; congested = pressure == 1; try r.finish()
 }
}
