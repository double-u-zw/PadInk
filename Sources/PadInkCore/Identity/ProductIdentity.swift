import Foundation

/// PadInk's public name is independent of its version and durable identifiers.
/// Keep existing keychain, discovery and USB identifiers when updating the public name.
/// Bundle IDs are build settings (Config/Identity.xcconfig), not runtime constants.
public enum ProductIdentity {
 public enum Variant: String, Codable { case development, release }
 public struct Namespace: Equatable {
  public let displayName: String, keychainService: String, bonjourServiceType: String
  public let usbLoopbackPort: UInt16
 }
 /// Missing metadata denotes the pre-split App. Preserve its pairing and USB identity.
 public static func variant(in bundle: Bundle) -> Variant {
  Variant(rawValue: bundle.object(forInfoDictionaryKey: "PadInkBuildVariant") as? String ?? "release") ?? .release
 }
 public static let buildVariant = variant(in: .main)
 public static func namespace(for variant: Variant) -> Namespace {
  switch variant {
  case .release: return Namespace(displayName: "PadInk", keychainService: "dev.padink03.trust", bonjourServiceType: "_pnk2._tcp", usbLoopbackPort: 42371)
  case .development: return Namespace(displayName: "PadInk", keychainService: "dev.padink03.trust.development", bonjourServiceType: "_pnk2-dev._tcp", usbLoopbackPort: 42372)
  }
 }
 public static var displayName: String { namespace(for: buildVariant).displayName }
 /// Keychain service for DeviceIdentity and TrustStore items.
 public static var keychainService: String { namespace(for: buildVariant).keychainService }
 /// Single iPad loopback port reached through usbmuxd. Both the control/input connection
 /// and the video connection use it; the first HELLO declares the connection kind.
 public static var usbLoopbackPort: UInt16 { namespace(for: buildVariant).usbLoopbackPort }
 /// Bonjour service type for paired Wi-Fi discovery. One service; connection kind in HELLO.
 public static var bonjourServiceType: String { namespace(for: buildVariant).bonjourServiceType }

 /// Historical durable identifiers must remain separate; the public brand can be shared.
 public enum Legacy {
  public static let keychainServices: Set<String> = ["app.padink.greenfield.v1"]
  public static let ports: Set<UInt16> = [49271, 49272, 49273]
  public static let bonjourPrefix = "_padink-"
  public static let bundleIDPrefix = "app.padink.greenfield."
  public static let installedAppName = "PadInk"
 }
}
