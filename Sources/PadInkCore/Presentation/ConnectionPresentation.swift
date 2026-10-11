import Foundation

/// Presentation only: does not decide reconnection, input ownership or transport selection.
public enum ConnectionPhase: Equatable {
 case waiting, connecting, waitingForVideo, active, recovering, paused, needsAttention

 /// Shared short labels. Detailed recovery instructions remain in the existing model status.
 public var title: String {
  switch self {
  case .waiting: "等待连接"
  case .connecting: "正在连接"
  case .waitingForVideo: "正在准备画面"
  case .active: "已连接"
  case .recovering: "正在恢复"
  case .paused: "已暂停连接"
  case .needsAttention: "需要处理"
  }
 }

 public var symbolName: String {
  switch self {
  case .waiting: "link"
  case .connecting, .recovering: "arrow.triangle.2.circlepath"
  case .waitingForVideo: "display"
  case .active: "checkmark.circle.fill"
  case .paused: "pause.circle"
  case .needsAttention: "exclamationmark.circle"
  }
 }

 /// A transport handshake is not a visible picture. Only .active ends the busy state.
 public var isBusy: Bool {
  switch self {
  case .connecting, .waitingForVideo, .recovering: true
  default: false
  }
 }
}

public struct ConnectionPresentation: Equatable {
 public let phase: ConnectionPhase
 public let message: String
 public init(phase: ConnectionPhase, message: String) { self.phase = phase; self.message = message }
 /// Geometry preparation (ready=false) precedes display; only its presentation acknowledgement
 /// can clear the waiting/recovery status on Mac.
 public static func confirmsVideo(_ frame: Frame) -> Bool {
  frame.type == .presentedGeometry && (try? PresentedGeometry(frame.payload))?.ready == true
 }
 public static func ended(_ end: AttachmentEnd, peer: String) -> Self {
  switch end {
  case .versionMismatch, .peerError(.versionMismatch):
   return Self(phase: .needsAttention, message: "版本不兼容：请用同一份源码更新 Mac 和 iPad 两端，再重新连接")
  case .peerError(.authenticationFailed):
   return Self(phase: .needsAttention, message: "配对未完成：请在 iPad 设置点“允许重新配对”，再在 Mac 点“重新连接”，并在两端确认")
  case .closedLocally(.forgetDevice), .peerGoodbye(.forgetDevice):
   return Self(phase: .paused, message: "设备配对已移除：请在 iPad 允许重新配对，再在 Mac 点“重新连接”")
  case .closedLocally(.userDisconnect), .peerGoodbye(.userDisconnect):
   return Self(phase: .paused, message: "已暂停连接：请在 Mac 点“重新连接”")
  case .peerGoodbye(.appBackground), .closedLocally(.appBackground):
   return Self(phase: .waiting, message: "等待 \(peer) 返回：请保持 iPad 上的 PadInk 在前台，并唤醒 Mac")
  case .dead:
   return Self(phase: .recovering, message: "连接中断，正在自动重连；请检查数据线或同一 Wi-Fi，并保持两端应用打开")
  case .handshakeTimeout:
   return Self(phase: .recovering, message: "连接超时，正在重试；请解锁 iPad 并打开 PadInk，USB 连接需信任这台 Mac")
  case .protocolViolation, .peerError:
   return Self(phase: .recovering, message: "通信异常，正在重连；持续出现时请更新两端并导出双端诊断")
  default:
   return Self(phase: .recovering, message: "连接正在恢复；请保持两端 PadInk 打开")
  }
 }
}

/// Announce only a confirmed change for the same peer, never a candidate or a failed USB dial.
public struct TransportPresentation {
 private var previous: (peer: Data, transport: TransportKind)?
 public init() {}
 public mutating func confirmed(_ transport: TransportKind, peer: Data) -> String? {
  defer { previous = (peer, transport) }
  guard let previous, previous.peer == peer, previous.transport != transport else { return nil }
  return transport == .usb ? "已从 Wi-Fi 切换到 USB" : "已从 USB 恢复 Wi-Fi"
 }
}
