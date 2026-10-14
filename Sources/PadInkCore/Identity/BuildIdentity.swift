import Foundation

/// Local build provenance. HELLO continues to carry only the existing short source label.
public struct BuildIdentity: Equatable {
 public enum Channel: String, Codable { case development, rc, release, preview }
 public enum Distribution: String, Codable { case developer, altstore, testflight, appstore, direct, unsigned, unknown }
 public let version: String, source: String, build: String
 public let channel: Channel, distribution: Distribution
 public let variant: ProductIdentity.Variant
 public let sourceRevision: String?, sourceDigest: String?

 public init(version: String, source: String?, build: String? = nil, channel: String? = nil,
             distribution: String? = nil, sourceRevision: String? = nil, sourceDigest: String? = nil, variant: String? = nil) {
  self.version = Self.safe(version, limit: 12) ?? "unknown"
  self.source = Self.safe(source, limit: 25) ?? "unknown"
  self.build = Self.safe(build, limit: 24) ?? "unknown"
  self.channel = channel == "dev" ? .development : Channel(rawValue: channel ?? "development") ?? .preview
  self.variant = ProductIdentity.Variant(rawValue: variant ?? "release") ?? .release
  self.distribution = Distribution(rawValue: distribution ?? (self.channel == .development ? "developer" : "unknown")) ?? .unknown
  self.sourceRevision = Self.hex(sourceRevision, count: 40)
  self.sourceDigest = Self.hex(sourceDigest, count: 64)
 }
 private static func safe(_ value: String?, limit: Int) -> String? {
  guard let value, !value.isEmpty, value.utf8.count <= limit,
        value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 95].contains($0) }) else { return nil }
  return value
 }
 private static func hex(_ value: String?, count: Int) -> String? {
  guard let value, value.utf8.count == count, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
  return value.lowercased()
 }
 public static var current: BuildIdentity { from(bundle: .main) }
 public static func from(bundle: Bundle) -> BuildIdentity {
  let value: (String) -> String? = { bundle.object(forInfoDictionaryKey: $0) as? String }
  let distribution = resolvedDistribution(declared: value("PadInkDistribution"), receiptName: bundle.appStoreReceiptURL?.lastPathComponent)
  return BuildIdentity(version: value("CFBundleShortVersionString") ?? "0.3.0-dev", source: value("PadInkSourceCommit"),
   build: value("CFBundleVersion"), channel: distribution == "appstore" ? "release" : value("PadInkReleaseChannel"), distribution: distribution,
   sourceRevision: value("PadInkSourceRevision"), sourceDigest: value("PadInkSourceDigest"), variant: value("PadInkBuildVariant"))
 }
 /// App Store and TestFlight distribute the same uploaded binary. Only a production receipt
 /// changes the installation guidance; missing receipts keep the declared channel.
 public static func resolvedDistribution(declared: String?, receiptName: String?) -> String? {
  guard declared == "testflight" || declared == "appstore" else { return declared }
  if receiptName == "sandboxReceipt" { return "testflight" }
  if receiptName == "receipt" { return "appstore" }
  return declared
 }
 public var usesProvisioningExpiryReminder: Bool { isDeveloperInstall || distribution == .altstore }
 /// Keep the source label and existing 32-byte HELLO limit; build/provenance stay local.
 public var wireVersion: String {
  let available = Hello.maxAppVersionBytes - source.utf8.count - 1
  return String(version.prefix(max(1, available))) + "@" + source
 }
 public var display: String { "\(version) (\(build)) · \(variant == .development ? "开发版" : "正式版") · \(channel.rawValue.uppercased()) · \(source)" }
 public var isDeveloperInstall: Bool { channel == .development && distribution == .developer }
 public var installationGuidance: String {
  switch distribution {
  case .altstore:
   return "iPad 客户端通过官方 AltStore Classic 安装与续签。iPad 免费签名通常约 7 天有效；Mac 保持 AltServer 运行，在 AltStore 的 My Apps 中使用 Refresh All，或启用 Background Refresh。续签前结束书写；请保留 App 和原账号，不要卸载或停用 App。"
  case .testflight: return "通过 TestFlight 安装与更新 iPad 版本；更新 Mac 时使用发包者提供的同一版安装包。测试版本有效期以 TestFlight 显示为准。"
  case .appstore: return "通过 App Store 安装与更新 iPad 版本，无需开发者模式或续签。Mac 辅助端从 PadInk 的 GitHub Releases 下载并安装；首次使用需允许屏幕录制与辅助功能，并在两端确认配对。"
  case .developer where isDeveloperInstall:
   return "Xcode 开发安装：免费 Apple ID 的 iPad 签名通常约 7 天有效，用原团队覆盖更新并保留设置与配对。日常开发推荐按开发者指南切换到官方 AltStore 管理安装与续签；Xcode 安装不会自动进入 AltStore 的管理列表。"
  case .unsigned: return "这是未签名预览构建，仅供开发检查。请向发包者获取签名的安装包。"
  default: return "使用发包者提供的 Mac 安装包与 iPad 安装链接，更新两端至同一版本；请保留现有 App 的配对设置。"
  }
 }
}
