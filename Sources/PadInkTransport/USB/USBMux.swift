#if os(macOS)
import Foundation
import Darwin

public enum USBMuxError: Error, Equatable { case socket(Int32), protocolError, refused(Int) }

/// Minimal client for the system usbmuxd daemon (ListDevices / Connect), ported from Baseline v0.1.0.
/// This is the only undocumented system interface on the product path (REWRITE_BRIEF §4.5); nothing
/// outside PadInkTransport/USB knows it exists.
public enum USBMux {
 public struct Device: Equatable { public let id: Int; public let serial: String }

 static func socket() throws -> Int32 {
  let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw USBMuxError.socket(errno) }
  var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
  let path = Array("/var/run/usbmuxd".utf8) + [0]
  withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let ok = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
  guard ok == 0 else { Darwin.close(fd); throw USBMuxError.socket(errno) }
  var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
  setTimeouts(fd, seconds: 2)
  return fd
 }
 static func setTimeouts(_ fd: Int32, seconds: Int) {
  var timeout = timeval(tv_sec: seconds, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
 }
 static func readExact(_ fd: Int32, _ count: Int) throws -> Data {
  var data = Data(count: count); var offset = 0
  try data.withUnsafeMutableBytes { raw in while offset < count { let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset); if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw USBMuxError.socket(errno) }; offset += n } }
  return data
 }
 static func writeAll(_ fd: Int32, _ data: Data) throws {
  try data.withUnsafeBytes { raw in var offset = 0; while offset < data.count { let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset); if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw USBMuxError.socket(errno) }; offset += n } }
 }
 static func request(_ fd: Int32, _ dict: [String: Any]) throws -> [String: Any] {
  var d = dict; d["ClientVersionString"] = "PadInk/2"; d["ProgName"] = "PadInk"; d["kLibUSBMuxVersion"] = 3
  let body = try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
  var bytes = Data(); for v: UInt32 in [UInt32(body.count + 16), 1, 8, 1] { var le = v.littleEndian; withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) } }; bytes.append(body); try writeAll(fd, bytes)
  let header = try readExact(fd, 16); let fields = header.withUnsafeBytes { r in (0..<4).map { UInt32(littleEndian: r.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) } }
  guard fields[0] >= 16, fields[0] <= 1_048_576, fields[1] == 1, fields[2] == 8, fields[3] == 1 else { throw USBMuxError.protocolError }
  let reply = try readExact(fd, Int(fields[0]) - 16)
  guard let result = try PropertyListSerialization.propertyList(from: reply, format: nil) as? [String: Any] else { throw USBMuxError.protocolError }; return result
 }
 /// Physically attached USB devices only (no Wi-Fi sync entries).
 public static func devices() throws -> [Device] {
  let fd = try socket(); defer { Darwin.close(fd) }
  let response = try request(fd, ["MessageType": "ListDevices"])
  return (response["DeviceList"] as? [[String: Any]] ?? []).compactMap { d in
   guard let p = d["Properties"] as? [String: Any], p["ConnectionType"] as? String == "USB", let id = d["DeviceID"] as? Int, let serial = p["SerialNumber"] as? String else { return nil }; return Device(id: id, serial: serial)
  }.sorted { $0.serial < $1.serial }
 }
 /// A connected stream fd to `port` on the device's loopback. Data sockets have no send timeout:
 /// backlog is judged by AttachmentLiveness, not by the socket (fault row 1).
 public static func connect(device: Device, port: UInt16) throws -> Int32 {
  let fd = try socket()
  do {
   let result = try request(fd, ["MessageType": "Connect", "DeviceID": device.id, "PortNumber": Int(port.bigEndian)])
   let number = result["Number"] as? Int ?? -1; guard number == 0 else { throw USBMuxError.refused(number) }
   setTimeouts(fd, seconds: 0)
   return fd
  } catch { Darwin.close(fd); throw error }
 }
}
#endif
