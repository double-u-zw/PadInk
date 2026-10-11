import Foundation

/// Reads the expiry of the app's embedded provisioning profile (free accounts: 7 days) so the iPad can
/// send it in HELLO and both sides can remind the user 3 days ahead (REWRITE_BRIEF §10.4).
/// embedded.mobileprovision is a CMS envelope around an XML plist; the plist is located by its
/// markers and parsed, no signature verification is needed for a reminder.
public enum ProvisioningProfile {
 public static func expiry(from data: Data) -> Date? {
  guard let start = data.range(of: Data("<?xml".utf8)) ?? data.range(of: Data("<plist".utf8)),
        let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.count) else { return nil }
  let plist = data.subdata(in: start.lowerBound..<end.upperBound)
  return (try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])?["ExpirationDate"] as? Date
 }
 /// Unix seconds, 0 when unknown (simulator, unsigned builds).
 public static func embeddedExpiry(bundle: Bundle = .main) -> UInt64 {
  guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"), let data = try? Data(contentsOf: url), let date = expiry(from: data) else { return 0 }
  return UInt64(max(0, date.timeIntervalSince1970))
 }
 public static func reminder(expiry: UInt64, now: Date = Date()) -> String? {
  guard expiry > 0 else { return nil }
  let remaining = TimeInterval(expiry) - now.timeIntervalSince1970
  guard remaining < 3 * 86_400 else { return nil }
  return remaining <= 0 ? "PadInk 签名已过期。请插上 iPad，在 Mac 上双击“更新 PadInk”。" : "PadInk 将在 \(max(1, Int(ceil(remaining / 86_400)))) 天内过期。请插上 iPad，在 Mac 上双击“更新 PadInk”。"
 }
}
