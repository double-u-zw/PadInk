import Foundation

public enum PayloadError: Error, Equatable { case length, value, reserved }

/// Cancel / rejection reason codes (PROTOCOL §6). Fixed from Phase 1; diagnostics use the same numbers.
public enum CancelReason: UInt8, CaseIterable {
 case transportLost = 1, gestureTimeout, geometryMismatch, staleSample, targetChanged, pencilPreempted, settingsChanged, appBackground, sessionReplaced, protocolViolation
}

public enum PeerRole: UInt8 { case mac = 1, ipad = 2 }

public struct Capabilities: OptionSet, Equatable {
 public let rawValue: UInt32
 public init(rawValue: UInt32) { self.rawValue = rawValue }
 public static let extendedVideo = Capabilities(rawValue: 1 << 3)
 public static let pencilHover = Capabilities(rawValue: 1 << 0)
 public static let pencilPressure = Capabilities(rawValue: 1 << 1)
 public static let pencilTilt = Capabilities(rawValue: 1 << 2)
}

/// HELLO and HELLO_ACK share one layout (PROTOCOL §4.1). The first 8 bytes are frozen forever so
/// that any future version can still explain a mismatch.
public struct Hello: Equatable {
 public static let maxAppVersionBytes = 32, maxNameBytes = 64
 public var minWireVersion: UInt16, maxWireVersion: UInt16
 public var connection: ConnectionKind, role: PeerRole
 public var appVersion: String
 public var deviceID: Data            // 32 bytes
 public var attachmentID: UUID
 public var resumeToken: Data         // 32 bytes; all zero = new logical session
 public var generation: UInt32        // HELLO: proposed by the Mac; ACK: confirmed by the iPad
 public var capabilities: Capabilities
 public var signingExpiry: UInt64     // iPad: Unix seconds of provisioning expiry; 0 = unknown / Mac
 public var displayName: String       // UI only; never exported in diagnostics
 public var drawableWidth: UInt32, drawableHeight: UInt32

 public init(minWireVersion: UInt16 = PINK2.wireVersion, maxWireVersion: UInt16 = PINK2.wireVersion, connection: ConnectionKind, role: PeerRole, appVersion: String, deviceID: Data, attachmentID: UUID, resumeToken: Data = Data(count: 32), generation: UInt32, capabilities: Capabilities = [], signingExpiry: UInt64 = 0, displayName: String = "", drawableWidth: UInt32 = 0, drawableHeight: UInt32 = 0) {
  self.minWireVersion = minWireVersion; self.maxWireVersion = maxWireVersion; self.connection = connection; self.role = role
  self.appVersion = Self.truncated(appVersion, Self.maxAppVersionBytes); self.deviceID = deviceID; self.attachmentID = attachmentID
  self.resumeToken = resumeToken; self.generation = generation; self.capabilities = capabilities; self.signingExpiry = signingExpiry
  self.displayName = Self.truncated(displayName, Self.maxNameBytes); self.drawableWidth = drawableWidth; self.drawableHeight = drawableHeight
 }

 /// Truncate at a valid UTF-8 boundary (Baseline testUnicodePeerNameTruncatesAtValidBoundary).
 static func truncated(_ text: String, _ limit: Int) -> String { var t = text; while t.utf8.count > limit { t.removeLast() }; return t }

 public func encoded() throws -> Data {
  guard deviceID.count == 32, resumeToken.count == 32, minWireVersion > 0, minWireVersion <= maxWireVersion, drawableWidth <= 8192, drawableHeight <= 8192 else { throw PayloadError.value }
  var w = ByteWriter()
  w.u16(minWireVersion); w.u16(maxWireVersion); w.u8(connection.rawValue); w.u8(role.rawValue); w.u16(0)
  let version = Data(appVersion.utf8); w.u8(UInt8(version.count)); w.bytes(version)
  w.bytes(deviceID); var u = attachmentID.uuid; withUnsafeBytes(of: &u) { w.bytes(Data($0)) }
  w.bytes(resumeToken); w.u32(generation); w.u32(capabilities.rawValue); w.u64(signingExpiry)
  let name = Data(displayName.utf8); w.u8(UInt8(name.count)); w.bytes(name)
  w.u32(drawableWidth); w.u32(drawableHeight)
  return w.data
 }

 public init(_ data: Data) throws {
  var r = ByteReader(data)
  minWireVersion = try r.u16(); maxWireVersion = try r.u16()
  guard let kind = ConnectionKind(rawValue: try r.u8()), let role = PeerRole(rawValue: try r.u8()) else { throw PayloadError.value }
  guard try r.u16() == 0 else { throw PayloadError.reserved }
  connection = kind; self.role = role
  appVersion = try Self.text(&r, limit: Self.maxAppVersionBytes)
  deviceID = try r.bytes(32)
  let u = [UInt8](try r.bytes(16)); attachmentID = UUID(uuid: (u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]))
  resumeToken = try r.bytes(32); generation = try r.u32(); capabilities = Capabilities(rawValue: try r.u32()); signingExpiry = try r.u64()
  displayName = try Self.text(&r, limit: Self.maxNameBytes)
  drawableWidth = try r.u32(); drawableHeight = try r.u32()
  do { try r.finish() } catch { throw PayloadError.length }
  guard minWireVersion > 0, minWireVersion <= maxWireVersion, drawableWidth <= 8192, drawableHeight <= 8192 else { throw PayloadError.value }
 }

 private static func text(_ r: inout ByteReader, limit: Int) throws -> String {
  let n = Int(try r.u8()); guard n <= limit, let s = String(data: try r.bytes(n), encoding: .utf8) else { throw PayloadError.value }; return s
 }

 /// The frozen prefix only: readable from any past or future HELLO.
 public static func versionRange(_ data: Data) throws -> ClosedRange<UInt16> {
  var r = ByteReader(data); let lo = try r.u16(), hi = try r.u16(); guard lo > 0, lo <= hi else { throw PayloadError.value }; return lo...hi
 }
}

/// Outcome of comparing wire-version ranges; the UI turns `update...` into Chinese text.
public enum VersionNegotiation: Equatable {
 case agreed(UInt16), updateThisDevice, updatePeer
 public static func negotiate(local: ClosedRange<UInt16>, remote: ClosedRange<UInt16>) -> Self {
  let lo = max(local.lowerBound, remote.lowerBound), hi = min(local.upperBound, remote.upperBound)
  if lo <= hi { return .agreed(hi) }
  return remote.upperBound < local.lowerBound ? .updatePeer : .updateThisDevice
 }
}

public struct Heartbeat: Equatable {
 public var nonce: UInt64
 public init(nonce: UInt64) { self.nonce = nonce }
 public func encoded() -> Data { var w = ByteWriter(); w.u64(nonce); return w.data }
 public init(_ data: Data) throws { var r = ByteReader(data); nonce = try r.u64(); do { try r.finish() } catch { throw PayloadError.length } }
}

/// Responder's monotonic receive/send times; offset estimates are diagnostics only and use A only.
public struct HeartbeatAck: Equatable {
 public var nonce: UInt64, receiveTime: UInt64, sendTime: UInt64
 public init(nonce: UInt64, receiveTime: UInt64, sendTime: UInt64) { self.nonce = nonce; self.receiveTime = receiveTime; self.sendTime = sendTime }
 public func encoded() -> Data { var w = ByteWriter(); w.u64(nonce); w.u64(receiveTime); w.u64(sendTime); return w.data }
 public init(_ data: Data) throws { var r = ByteReader(data); nonce = try r.u64(); receiveTime = try r.u64(); sendTime = try r.u64(); do { try r.finish() } catch { throw PayloadError.length } }
}

public enum GoodbyeReason: UInt8 { case userDisconnect = 1, appBackground, appQuit, forgetDevice, settingsChanged }

public struct Goodbye: Equatable {
 public var reason: GoodbyeReason
 public init(reason: GoodbyeReason) { self.reason = reason }
 public func encoded() -> Data { Data([reason.rawValue]) }
 public init(_ data: Data) throws { guard data.count == 1 else { throw PayloadError.length }; guard let r = GoodbyeReason(rawValue: data[0]) else { throw PayloadError.value }; reason = r }
}

public enum ErrorCode: UInt16 { case versionMismatch = 1, protocolViolation, authenticationFailed, attachmentMismatch, busy }

public struct ErrorMessage: Equatable {
 public static let maxDetail = 200
 public var code: ErrorCode, faultRow: UInt8, detail: String
 /// `detail` is ASCII diagnostics only: no window titles, document names or paths.
 public init(code: ErrorCode, faultRow: UInt8, detail: String = "") {
  self.code = code; self.faultRow = faultRow
  self.detail = String(detail.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }.prefix(Self.maxDetail).map(Character.init))
 }
 public func encoded() -> Data { var w = ByteWriter(); w.u16(code.rawValue); w.u8(faultRow); w.u8(0); let d = Data(detail.utf8); w.u8(UInt8(d.count)); w.bytes(d); return w.data }
 public init(_ data: Data) throws {
  var r = ByteReader(data); guard let c = ErrorCode(rawValue: try r.u16()) else { throw PayloadError.value }
  let row = try r.u8(); guard try r.u8() == 0 else { throw PayloadError.reserved }
  let n = Int(try r.u8()); guard n <= Self.maxDetail, let d = String(data: try r.bytes(n), encoding: .ascii) else { throw PayloadError.value }
  do { try r.finish() } catch { throw PayloadError.length }
  code = c; faultRow = row; detail = d
 }
}

/// iPad -> Mac: the geometry generation Metal actually presented (PROTOCOL §4.6).
public struct PresentedGeometry: Equatable {
 public var generation: UInt32, ready: Bool, orientation: UInt8, videoWidth: UInt32, videoHeight: UInt32
 public init(generation: UInt32, ready: Bool, orientation: UInt8, videoWidth: UInt32, videoHeight: UInt32) { self.generation = generation; self.ready = ready; self.orientation = orientation; self.videoWidth = videoWidth; self.videoHeight = videoHeight }
 public func encoded() -> Data { var w = ByteWriter(); w.u32(generation); w.u8(ready ? 1 : 0); w.u8(orientation); w.u16(0); w.u32(videoWidth); w.u32(videoHeight); return w.data }
 public init(_ data: Data) throws {
  var r = ByteReader(data); generation = try r.u32(); let flag = try r.u8(); orientation = try r.u8(); guard try r.u16() == 0 else { throw PayloadError.reserved }
  videoWidth = try r.u32(); videoHeight = try r.u32(); do { try r.finish() } catch { throw PayloadError.length }
  guard generation > 0, flag <= 1 else { throw PayloadError.value }; ready = flag == 1
 }
}

/// INPUT_CANCEL (iPad -> Mac) and INPUT_REJECTED (Mac -> iPad) share this layout.
public struct GestureNotice: Equatable {
 public var gestureID: UInt64, reason: CancelReason
 public init(gestureID: UInt64, reason: CancelReason) { self.gestureID = gestureID; self.reason = reason }
 public func encoded() -> Data { var w = ByteWriter(); w.u64(gestureID); w.u8(reason.rawValue); return w.data }
 public init(_ data: Data) throws {
  var r = ByteReader(data); gestureID = try r.u64(); guard let reason = CancelReason(rawValue: try r.u8()) else { throw PayloadError.value }
  do { try r.finish() } catch { throw PayloadError.length }; guard gestureID > 0 else { throw PayloadError.value }; self.reason = reason
 }
}

public struct GestureKeepalive: Equatable {
 public var gestureID: UInt64, lastSampleSequence: UInt32
 public init(gestureID: UInt64, lastSampleSequence: UInt32) { self.gestureID = gestureID; self.lastSampleSequence = lastSampleSequence }
 public func encoded() -> Data { var w = ByteWriter(); w.u64(gestureID); w.u32(lastSampleSequence); return w.data }
 public init(_ data: Data) throws {
  var r = ByteReader(data); gestureID = try r.u64(); lastSampleSequence = try r.u32(); do { try r.finish() } catch { throw PayloadError.length }
  guard gestureID > 0, lastSampleSequence > 0 else { throw PayloadError.value }
 }
}
