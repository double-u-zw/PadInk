import Foundation

/// The two physical connections of a transport attachment. Input and video never share one,
/// so a large video frame cannot delay Pencil down/up (Baseline design, REWRITE_BRIEF §5).
public enum ConnectionKind: UInt8, CaseIterable { case controlInput = 1, video = 2 }

/// Logical channel of a message (docs/ARCHITECTURE.md §3). Control rides on both connections
/// where listed; Input only on controlInput; Video only on video.
public enum LogicalChannel: Equatable { case control, input, video }

public struct MessageType: RawRepresentable, Hashable, Equatable {
 public let rawValue: UInt16
 public init(rawValue: UInt16) { self.rawValue = rawValue }
 // Control 0x00xx
 public static let hello = Self(rawValue: 0x0001), helloAck = Self(rawValue: 0x0002)
 public static let authProof = Self(rawValue: 0x0003), authResult = Self(rawValue: 0x0004)
 public static let heartbeat = Self(rawValue: 0x0010), heartbeatAck = Self(rawValue: 0x0011)
 public static let goodbye = Self(rawValue: 0x0020), error = Self(rawValue: 0x0021)
 public static let presentedGeometry = Self(rawValue: 0x0030), inputSettings = Self(rawValue: 0x0031), status = Self(rawValue: 0x0032)
 public static let diagnosticRequest = Self(rawValue: 0x0050), diagnosticReply = Self(rawValue: 0x0051)
 // Input 0x01xx
 public static let pencil = Self(rawValue: 0x0101), pointer = Self(rawValue: 0x0102), scroll = Self(rawValue: 0x0103)
 public static let magnify = Self(rawValue: 0x0104), inputCancel = Self(rawValue: 0x0105), gestureKeepalive = Self(rawValue: 0x0106)
 public static let inputRejected = Self(rawValue: 0x0110)
 // Video 0x02xx
 public static let videoConfig = Self(rawValue: 0x0201), videoFrame = Self(rawValue: 0x0202), keyframeRequest = Self(rawValue: 0x0203)
 public static let videoFeedback = Self(rawValue: 0x0204), videoProfile = Self(rawValue: 0x0205)
}

public struct MessageSpec {
 public let type: MessageType, name: String, channel: LogicalChannel
 public let connections: Set<ConnectionKind>
 /// Required messages are sent with FrameFlags.critical; a receiver that does not know a
 /// critical type must fail the connection. Optional ones may be ignored by older peers.
 public let required: Bool
 public let maxPayload: Int
 /// Phase that defines the payload codec. Until then the payload layout is a draft.
 public let phase: Int
}

/// Single source of truth for PINK/2 message types. docs/PROTOCOL.md §3 mirrors this table;
/// MessageRegistryTests fails when they diverge.
public enum MessageRegistry {
 private static let both: Set<ConnectionKind> = [.controlInput, .video]
 public static let all: [MessageSpec] = [
  .init(type: .hello, name: "HELLO", channel: .control, connections: both, required: true, maxPayload: 1024, phase: 1),
  .init(type: .helloAck, name: "HELLO_ACK", channel: .control, connections: both, required: true, maxPayload: 1024, phase: 1),
  .init(type: .authProof, name: "AUTH_PROOF", channel: .control, connections: both, required: true, maxPayload: 256, phase: 2),
  .init(type: .authResult, name: "AUTH_RESULT", channel: .control, connections: both, required: true, maxPayload: 64, phase: 2),
  .init(type: .heartbeat, name: "HEARTBEAT", channel: .control, connections: both, required: true, maxPayload: 16, phase: 1),
  .init(type: .heartbeatAck, name: "HEARTBEAT_ACK", channel: .control, connections: both, required: true, maxPayload: 32, phase: 1),
  .init(type: .goodbye, name: "GOODBYE", channel: .control, connections: both, required: true, maxPayload: 8, phase: 1),
  .init(type: .error, name: "ERROR", channel: .control, connections: both, required: true, maxPayload: 512, phase: 1),
  .init(type: .presentedGeometry, name: "PRESENTED_GEOMETRY", channel: .control, connections: [.controlInput], required: true, maxPayload: 64, phase: 1),
  .init(type: .inputSettings, name: "INPUT_SETTINGS", channel: .control, connections: [.controlInput], required: true, maxPayload: 16, phase: 3),
  .init(type: .status, name: "STATUS", channel: .control, connections: [.controlInput], required: false, maxPayload: 1024, phase: 2),
  .init(type: .diagnosticRequest, name: "DIAGNOSTIC_REQUEST", channel: .control, connections: [.controlInput], required: false, maxPayload: 16, phase: 2),
  .init(type: .diagnosticReply, name: "DIAGNOSTIC_REPLY", channel: .control, connections: [.controlInput], required: false, maxPayload: 32 * 1024, phase: 2),
  .init(type: .pencil, name: "PENCIL", channel: .input, connections: [.controlInput], required: true, maxPayload: PencilBatch.maxPayload, phase: 1),
  .init(type: .pointer, name: "POINTER", channel: .input, connections: [.controlInput], required: true, maxPayload: 64, phase: 3),
  .init(type: .scroll, name: "SCROLL", channel: .input, connections: [.controlInput], required: true, maxPayload: 64, phase: 3),
  .init(type: .magnify, name: "MAGNIFY", channel: .input, connections: [.controlInput], required: true, maxPayload: 64, phase: 3),
  .init(type: .inputCancel, name: "INPUT_CANCEL", channel: .input, connections: [.controlInput], required: true, maxPayload: 32, phase: 1),
  .init(type: .gestureKeepalive, name: "GESTURE_KEEPALIVE", channel: .input, connections: [.controlInput], required: true, maxPayload: 32, phase: 1),
  .init(type: .inputRejected, name: "INPUT_REJECTED", channel: .input, connections: [.controlInput], required: true, maxPayload: 32, phase: 1),
  .init(type: .videoConfig, name: "VIDEO_CONFIG", channel: .video, connections: [.video], required: true, maxPayload: 64 * 1024, phase: 1),
  .init(type: .videoFrame, name: "VIDEO_FRAME", channel: .video, connections: [.video], required: true, maxPayload: 8 * 1024 * 1024, phase: 1),
  .init(type: .keyframeRequest, name: "KEYFRAME_REQUEST", channel: .video, connections: [.video], required: true, maxPayload: 8, phase: 1),
  // extendedVideo: 14-byte actual hardware decode acknowledgement and bounded-queue pressure; older peers never receive it.
 .init(type: .videoFeedback, name: "VIDEO_FEEDBACK", channel: .video, connections: [.video], required: false, maxPayload: 64, phase: 2),
  .init(type: .videoProfile, name: "VIDEO_PROFILE", channel: .video, connections: [.video], required: false, maxPayload: 64, phase: 2),
 ]
 private static let index = Dictionary(uniqueKeysWithValues: all.map { ($0.type, $0) })
 public static func spec(_ type: MessageType) -> MessageSpec? { index[type] }
}
