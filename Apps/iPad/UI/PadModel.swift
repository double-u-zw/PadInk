import Foundation
import Combine
import PadInkCore

/// UI state, main thread only.
public final class PadModel: ObservableObject {
 @Published public var touchEnabled = UserDefaults.standard.object(forKey: "touchEnabled") as? Bool ?? true
 @Published public var transport = "USB"
 @Published public var lanNote: String?
 @Published public var lanPairing: LANPairingPrompt?
 @Published public var pairing: PairingRequest?
 @Published public var trustedDevices: [PairingRequest] = []
 @Published public var connected = false
 @Published public var sessionActive = false
 @Published public var phase: ConnectionPhase = .waiting
 @Published public var transportNotice: String?
 @Published public var status = "等待 Mac 连接"
 @Published public var videoNote: String?
 @Published public var usbNote: String?
 @Published public var peerVersion: String?
 public let buildIdentity = BuildIdentity.current
 public let localVersion = BuildIdentity.current.display
 @Published public var previousSessionNote: String?
 @Published public var macName = ""
 @Published public var signingReminder: String?
 @Published public var lastInputNote: String?
 @Published public var exportURL: URL?
 @Published public var exportNote: String?
 @Published public var exportingDiagnostics = false
 public init() {}
 /// Presentation arrives at video cadence. Notify SwiftUI only for an actual state transition.
 /// Geometry still acknowledges every presented frame independently in PencilView.
 @discardableResult public func videoPresented() -> Bool {
  let ready = "已连接 · \(transport)"
  guard status != ready || videoNote != nil || phase != .active else { return false }
  if phase != .active { phase = .active }
  if status != ready { status = ready }
  if videoNote != nil { videoNote = nil }
  return true
 }
}

