import Foundation

/// Diagnostic clock estimate only. Never adjusts input timestamps, liveness or sample age.
public struct ClockEstimate: Codable, Equatable {
 public let offsetMilliseconds: Double, uncertaintyMilliseconds: Double, roundTripMilliseconds: Double
 public var reliable: Bool { uncertaintyMilliseconds <= 25 }
 public init?(sent: UInt64, peerReceived: UInt64, peerSent: UInt64, received: UInt64) {
  guard received >= sent, peerSent >= peerReceived, peerSent - peerReceived <= received - sent else { return nil }
  let rtt = Double(received - sent) - Double(peerSent - peerReceived)
  offsetMilliseconds = ((Double(peerReceived) - Double(sent)) + (Double(peerSent) - Double(received))) / 2e6
  uncertaintyMilliseconds = rtt / 2e6; roundTripMilliseconds = Double(received - sent) / 1e6
 }
}

/// Explicit support fields: no device name, public/private key, token, title, path or document.
public struct SessionDiagnostics: Codable {
 public var role = "unknown", transport = "none", connection = "idle"
 public var generation: UInt32 = 0, reconnects = 0
 public var peerID: String?, peerAppVersion: String?, signingExpiry: UInt64?
 public var rttMilliseconds: Double?, clock: ClockEstimate?
 public var inputOwner = "none", gesture: UInt64?, applicationStrategy = "nativePencil"
 public var queuedVideoBytes = 0, videoProfile = "usbFull", bitrate = 0
 public var model = "unknown", operatingSystem = "unknown", appVersion = "unknown"
 public var sourceBuild: String?, videoState: String?, lastVideoError: String?
 public var buildVariant: String?, buildNumber: String?, releaseChannel: String?, distribution: String?, sourceRevision: String?, sourceDigest: String?
 /// Discovery/listener health is independent of the actual active attachment transport.
 public var usbDialStage: String?, usbDialError: String?, usbDeviceCount: Int?, usbDialAttempts: UInt64?
 public var usbListenerState: String?, usbListenerError: String?, usbAttachmentError: String?
 public var decodePendingFrames: Int?, decodePendingBytes: Int?, decodeInFlightBytes: Int?
 public var decodePeakPendingFrames: Int?, decodePeakRetainedBytes: Int?, decodeDroppedFrames: UInt64?
 public var decodeRecoveries: UInt64?, decodeWaitingForIDR: Bool?, decodeWorkers: Int?
 public var inputPendingFrames: Int?, inputPendingBytes: Int?, inputInFlightBytes: Int?
 public var inputOldestAgeMilliseconds: Double?, inputDroppedGestures: UInt64?, inputStalls: UInt64?
 public init() {}
 public mutating func applyBuild(_ build: BuildIdentity) {
  appVersion = build.version; sourceBuild = build.source; buildNumber = build.build
  buildVariant = build.variant.rawValue; releaseChannel = build.channel.rawValue; distribution = build.distribution.rawValue
  sourceRevision = build.sourceRevision; sourceDigest = build.sourceDigest
 }
}

public struct DiagnosticMetrics: Codable {
 public var captureFPS: Double?, presentFPS: Double?
 public var encodeFPS: Double?, decodeFPS: Double?
 public var averageVideoMbps: Double?, peakOneSecondVideoMbps: Double?, videoWindowSeconds: Double?
 public var presentationIntervalsMilliseconds: Distribution?
 public var encodeMilliseconds: Distribution?, decodeMilliseconds: Distribution?
 public var captureToSendMilliseconds: Distribution?, receiveToInjectMilliseconds: Distribution?
 public var receiveToPresentMilliseconds: Distribution?
 public init(traces: [Trace], now: UInt64) {
  let recent = traces.filter { $0.time <= now && now - $0.time < 2_000_000_000 }
  func fps(_ stage: String) -> Double? {
   guard traces.contains(where: { $0.stage == stage }) else { return nil }
   return Double(recent.filter { $0.stage == stage }.count) / 2
  }
  encodeFPS = fps("video.encoded"); decodeFPS = fps("video.decoded")
  let bytes = traces.filter { ($0.stage == "video.send" || $0.stage == "video.received") && $0.value != nil }.sorted { $0.time < $1.time }
  if let first = bytes.first, let last = bytes.last, last.time > first.time {
   let seconds = Double(last.time - first.time) / 1e9
   videoWindowSeconds = seconds
   averageVideoMbps = bytes.dropFirst().reduce(0) { $0 + ($1.value ?? 0) } * 8 / seconds / 1e6
   // Maximum sliding one-second window; do not infer bandwidth from a target property.
   var left = 0, sum = 0.0, peak = 0.0
   for right in bytes.indices {
    sum += bytes[right].value ?? 0
    while bytes[right].time - bytes[left].time >= 1_000_000_000 { sum -= bytes[left].value ?? 0; left += 1 }
    if bytes[right].time - first.time >= 1_000_000_000 { peak = max(peak, sum) }
   }
   if seconds >= 1 { peakOneSecondVideoMbps = peak * 8 / 1e6 }
  }
  if traces.contains(where: { $0.stage == "video.presented" }) { presentationIntervalsMilliseconds = TimingStats.intervals(traces, stage: "video.presented") }
  captureFPS = fps("video.capture"); presentFPS = fps("video.presented")
  func values(_ stage: String) -> Distribution? {
   let samples = traces.filter { $0.stage == stage }.compactMap(\.value).filter { $0.isFinite && $0 >= 0 }
   return samples.isEmpty ? nil : Distribution(samples)
  }
  encodeMilliseconds = values("video.encoded"); decodeMilliseconds = values("video.decoded")
  captureToSendMilliseconds = values("input.captureToSend"); receiveToInjectMilliseconds = values("input.receiveToInject")
  receiveToPresentMilliseconds = values("video.receiveToPresent")
 }
}

/// A separate bounded journal survives high-rate video/input trace turnover.
public struct FaultRecord: Codable, Equatable {
 public let time: UInt64, generation: UInt32, row: String, reason: String
 public init(time: UInt64, generation: UInt32, row: String, reason: String) { self.time = time; self.generation = generation; self.row = row; self.reason = reason }
}

public extension AttachmentEnd {
 /// Fixed reason codes, safe to export without an underlying error description.
 var diagnosticFault: (row: String, reason: String) {
  switch self {
  case .dead(.controlFailed): return ("7", "controlFailed")
  case .dead(.controlSilent): return ("7", "controlSilent")
  case .protocolViolation: return ("8", "protocolViolation")
  case .peerError(.authenticationFailed): return ("8", "authenticationFailed")
  case .versionMismatch, .peerError(.versionMismatch): return ("8", "versionMismatch")
  case .peerError: return ("8", "peerError")
  case .handshakeTimeout: return ("7", "handshakeTimeout")
  case .peerGoodbye: return ("7", "peerGoodbye")
  case .closedLocally: return ("7", "closedLocally")
  case .replaced: return ("7", "sessionReplaced")
  }
 }
}

public extension CancelReason {
 /// User/lifecycle cancellations are ordinary state changes, not protocol faults.
 var diagnosticFaultRow: String? {
  switch self {
  case .staleSample: return "2"
  case .geometryMismatch: return "4"
  case .targetChanged: return "5"
  case .gestureTimeout: return "6"
  case .transportLost, .sessionReplaced: return "7"
  case .protocolViolation: return "8"
  case .pencilPreempted, .settingsChanged, .appBackground: return nil
  }
 }
}

/// Numeric media facts persist even when the bounded per-frame ring turns over. No image content.
public struct VideoRuntime: Codable, Equatable {
 public var sourceWidth: Int?, sourceHeight: Int?, captureWidth: Int?, captureHeight: Int?
 public var encodedWidth: Int?, encodedHeight: Int?, drawableWidth: Int?, drawableHeight: Int?
 public var viewportWidth: Int?, viewportHeight: Int?, targetBitrate: Int?
 public var codec: VideoCodec?, hardwareEncoder: Bool?, hardwareDecoder: Bool?
 public var encodedPixelFormat: UInt32?, decodedPixelFormat: UInt32?
 public var captureMatrix709: Bool?, captureTransferSRGB: Bool?, captureTransfer709: Bool?
 public var captureScaleFactor: Double?, captureContentScale: Double?
 public var decodedFrames: UInt64 = 0
 public init() {}
}
