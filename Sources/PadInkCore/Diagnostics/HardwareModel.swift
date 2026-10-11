import Foundation
import Darwin

/// Product model only, never a serial number, device name, account or persistent identifier.
public enum HardwareModel {
 public static let current: String = {
  #if os(macOS)
  let key = "hw.model"
  #else
  let key = "hw.machine"
  #endif
  var size = 0
  guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1, size <= 128 else { return "unknown" }
  var bytes = [CChar](repeating: 0, count: size)
  guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "unknown" }
  return String(cString: bytes)
 }()
}
