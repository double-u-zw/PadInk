public enum TransportKind: String, Codable { case usb, wifi }
public struct TransportSelection {
 public enum Action: Equatable { case stay, connect(TransportKind), cancelInputAndSwitchToUSB }
 private var usbWaitingSince: UInt64?
 public init() {}
 public mutating func decide(current: TransportKind?, usbAvailable: Bool, lanAvailable: Bool, inputActive: Bool, paused: Bool, now: UInt64) -> Action {
  guard !paused else { usbWaitingSince = nil; return .stay }
  guard let current else { usbWaitingSince = nil; return usbAvailable ? .connect(.usb) : lanAvailable ? .connect(.wifi) : .stay }
  guard current == .wifi, usbAvailable else { usbWaitingSince = nil; return .stay }
  if !inputActive { usbWaitingSince = nil; return .connect(.usb) }
  if usbWaitingSince == nil { usbWaitingSince = now }
  if now >= usbWaitingSince!, now - usbWaitingSince! >= 500_000_000 { usbWaitingSince = nil; return .cancelInputAndSwitchToUSB }
  return .stay
 }
}
