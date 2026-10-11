import Foundation
import CryptoKit

public struct LANPairingPrompt: Equatable { public let name: String, code: String }
/// Pairing-only commit/reveal protocol; it can never carry product data. Both peers commit before
/// revealing, compare the six-digit SAS, then exchange pair-key-bound consent and stored receipts.
public final class LANPairing {
 private let identity: DeviceIdentity, store: TrustStore, role: PeerRole, reveal: Data, commitment: Data
 private var peerCommit: Data?, peerReveal: Data?, peerKey: Data?, peerPublic: Data?, peerName = ""
 private var localConsent = false, remoteConsent = false, stored = false, sentReveal = false, finished = false, started = false
 public var send: (Data) -> Void = { _ in }, onPrompt: (LANPairingPrompt) -> Void = { _ in }, onComplete: (Bool) -> Void = { _ in }
 public init(identity: DeviceIdentity, store: TrustStore, role: PeerRole, name: String, nonce: Data = LogicalSession.newToken()) {
  precondition(nonce.count == 32); self.identity = identity; self.store = store; self.role = role
  var name = name; while name.utf8.count > 64 { name.removeLast() }
  reveal = identity.publicKey + nonce + Data([UInt8(name.utf8.count)]) + Data(name.utf8)
  commitment = Data(SHA256.hash(data: Data("PadInk SAS commitment v1".utf8) + Data([role.rawValue]) + reveal))
 }
 public func start() { guard !finished, !started else { return }; started = true; send(Data([1, role.rawValue]) + commitment) }
 public func cancel() { finish(false) }
 public func receive(_ data: Data) {
  guard !finished else { return }; guard started, let stage = data.first else { return finish(false) }
  switch stage {
  case 1:
   guard data.count == 34, peerCommit == nil, data[1] == (role == .mac ? PeerRole.ipad.rawValue : PeerRole.mac.rawValue) else { return finish(false) }
   peerCommit = Data(data.dropFirst(2)); sentReveal = true; send(Data([2]) + reveal)
  case 2:
   guard sentReveal, let peerCommit, peerReveal == nil, (66...130).contains(data.count) else { return finish(false) }
   let body = Data(data.dropFirst()), peerRole: PeerRole = role == .mac ? .ipad : .mac
   guard body.count == 65 + Int(body[64]), let name = String(data: body.dropFirst(65), encoding: .utf8),
         Data(SHA256.hash(data: Data("PadInk SAS commitment v1".utf8) + Data([peerRole.rawValue]) + body)) == peerCommit else { return finish(false) }
   let pub = Data(body.prefix(32)); guard DeviceIdentity.id(publicKey: pub) != identity.id else { return finish(false) }
   do { peerKey = try identity.pairKey(with: pub) } catch { return finish(false) }
   peerPublic = pub; peerReveal = body; peerName = name
   let hash = Data(SHA256.hash(data: transcript(label: "code")))
   let number = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
   onPrompt(LANPairingPrompt(name: name, code: String(format: "%06u", number)))
  case 3:
   guard data.count == 33, peerReveal != nil, !remoteConsent, valid(Data(data.dropFirst()), label: "consent", local: false) else { return finish(false) }
   remoteConsent = true; persistIfReady()
  case 4:
   guard data.count == 33, stored, valid(Data(data.dropFirst()), label: "stored", local: false) else { return finish(false) }
   finish(true)
  default: finish(false)
  }
 }
 public func confirm(_ accepted: Bool) {
  guard !finished, peerReveal != nil, !localConsent else { return }
  guard accepted else { return finish(false) }; localConsent = true
  send(Data([3]) + tag(label: "consent", local: true)); persistIfReady()
 }
 private func persistIfReady() {
  guard localConsent, remoteConsent, !stored, let peerPublic, let peerKey else { return }
  do { try store.put(TrustedPeer(publicKey: peerPublic, pairKey: peerKey, name: peerName)) } catch { return finish(false) }
  stored = true; send(Data([4]) + tag(label: "stored", local: true))
 }
 private func transcript(label: String, local: Bool? = nil) -> Data {
  guard let peerReveal else { return Data() }
  let ordered = role == .mac ? reveal + peerReveal : peerReveal + reveal
  let sender = local.map { $0 ? role.rawValue : (role == .mac ? PeerRole.ipad.rawValue : PeerRole.mac.rawValue) } ?? 0
  return Data("PadInk SAS v1\0\(label)\0".utf8) + Data([sender]) + ordered
 }
 private func tag(label: String, local: Bool) -> Data { Data(HMAC<SHA256>.authenticationCode(for: transcript(label: label, local: local), using: SymmetricKey(data: peerKey!))) }
 private func valid(_ data: Data, label: String, local: Bool) -> Bool { guard let peerKey else { return false }; return HMAC<SHA256>.isValidAuthenticationCode(data, authenticating: transcript(label: label, local: local), using: SymmetricKey(data: peerKey)) }
 private func finish(_ success: Bool) { guard !finished else { return }; finished = true; onComplete(success) }
}

public enum LANKeys {
 /// TLS PSK is separately derived; USB and LAN still share one long-term pair record.
 public static func tlsKey(_ pairKey: Data) -> Data {
  let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: pairKey), salt: Data("PadInk TLS v1".utf8), info: Data(), outputByteCount: 32)
  return key.withUnsafeBytes { Data($0) }
 }
 public static func label(local: Data, peer: Data) -> String {
  let ids = [local, peer].sorted { $0.lexicographicallyPrecedes($1) }
  return Data(SHA256.hash(data: ids[0] + ids[1])).base64EncodedString()
 }
 public static func serviceName(_ id: Data) -> String { id.base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "") }
 public static func deviceID(_ serviceName: String) -> Data? {
  guard serviceName.count == 43, let data = Data(base64Encoded: serviceName.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+") + "="), data.count == 32 else { return nil }; return data
 }
}
