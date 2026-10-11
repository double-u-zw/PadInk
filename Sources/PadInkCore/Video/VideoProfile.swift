import Foundation

public enum VideoQuality: String, Codable, CaseIterable { case full, reducedBitrate, reducedFrameRate }
/// USB starting values; human latency/quality measurements remain deferred.
public struct VideoProfile: Equatable, Codable {
 public let quality: VideoQuality
 public let transport: TransportKind
 public var framesPerSecond: Int { quality == .reducedFrameRate ? 30 : 60 }
 public var bitrateScale: Double { (quality == .full ? 1 : 0.5) * (transport == .wifi ? 0.35 : 1) }
 public var keyframeInterval: Int { framesPerSecond }
 public init(_ quality: VideoQuality = .full, transport: TransportKind = .usb) { self.quality = quality; self.transport = transport }
}
/// Hysteresis avoids repeated quality changes on a fluctuating link. No session/input actions.
public struct VideoAdaptation {
 public private(set) var profile = VideoProfile()
 private var congestedSince: UInt64?, healthySince: UInt64?
 public init(transport: TransportKind = .usb) { profile = VideoProfile(transport: transport) }
 public mutating func update(congested: Bool, now: UInt64) -> VideoProfile? {
  let previous = profile
  if congested {
   healthySince = nil; if congestedSince == nil { congestedSince = now }
   let age = now >= congestedSince! ? now - congestedSince! : 0
   if age >= 3_000_000_000 { profile = VideoProfile(.reducedFrameRate, transport: profile.transport) }
   else if age >= 1_000_000_000, profile.quality == .full { profile = VideoProfile(.reducedBitrate, transport: profile.transport) }
  } else {
   congestedSince = nil; if healthySince == nil { healthySince = now }
   if now >= healthySince!, now - healthySince! >= 10_000_000_000 { profile = VideoProfile(transport: profile.transport) }
  }
  return profile == previous ? nil : profile
 }
}

/// Receiver-local timing only. A static desktop is not a freeze; new arrivals without
/// presentation, or a late presentation, retain pressure briefly. Epoch fences old callbacks.
public final class VideoPresentationPressure {
 private let lock = NSLock()
 private var epoch: UUID?, lastReceived: UInt64 = 0, lastPresented: UInt64 = 0, until: UInt64 = 0
 public init() {}
 public func reset(epoch: UUID) { lock.lock(); defer { lock.unlock() }; self.epoch = epoch; lastReceived = 0; lastPresented = 0; until = 0 }
 public func received(epoch: UUID, now: UInt64) { lock.lock(); defer { lock.unlock() }; guard self.epoch == epoch else { return }; lastReceived = max(lastReceived, now) }
 public func presented(epoch: UUID, received: UInt64, now: UInt64) {
  lock.lock(); defer { lock.unlock() }; guard self.epoch == epoch else { return }
  if now >= received, now - received > 80_000_000 { until = now + 1_500_000_000 }
  lastPresented = max(lastPresented, now)
 }
 public func congested(now: UInt64) -> Bool {
  lock.lock(); defer { lock.unlock() }
  return now < until || (lastPresented > 0 && lastReceived > lastPresented && now >= lastPresented && now - lastPresented > 200_000_000)
 }
}
