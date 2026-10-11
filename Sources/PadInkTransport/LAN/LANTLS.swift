import Foundation
import Network
import Security
import PadInkCore

public enum LANTLS {
 public static func parameters(keys: [(String, Data)]) throws -> NWParameters {
  guard !keys.isEmpty, keys.count <= 32, keys.allSatisfy({ !$0.0.isEmpty && $0.0.utf8.count <= 64 && $0.1.count == 32 }) else { throw StreamError.failed("tlsKeys") }
  let tls = NWProtocolTLS.Options(), options = tls.securityProtocolOptions
  sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12); sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
  sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00a8)!) // TLS_PSK_WITH_AES_128_GCM_SHA256
  for (label,key) in keys {
   let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }, identity = Data(label.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
   sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
  }
  // No certificate-based or plaintext fallback is accepted.
  sec_protocol_options_set_verify_block(options, { _,_,complete in complete(false) }, DispatchQueue.global(qos: .userInitiated))
  let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
  let p = NWParameters(tls: tls, tcp: tcp); p.includePeerToPeer = false; return p
 }
 public static func confirmed(_ connection: NWConnection) -> Bool {
  guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
  return sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv12 && sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue == 0x00a8
 }
 public static func stream(to endpoint: NWEndpoint, local: Data, peer: TrustedPeer, queue: DispatchQueue) throws -> NWStream {
  let stream = NWStream(NWConnection(to: endpoint, using: try parameters(keys: [(LANKeys.label(local: local, peer: peer.deviceID), LANKeys.tlsKey(peer.pairKey))])), queue: queue)
  stream.readyCheck = confirmed; return stream
 }
}

/// A pairing-only socket with its own small length framing. It never becomes a product ByteStream.
public final class LANPairingSocket {
 private let stream: ByteStream, exchange: LANPairing, queue: DispatchQueue
 private var keepAlive: LANPairingSocket?
 private var buffer = Data(), completed: Bool?, pendingSends = 0, closed = false
 public var onPrompt: (LANPairingPrompt) -> Void = { _ in }, onComplete: (Bool) -> Void = { _ in }
 public init(stream: ByteStream, identity: DeviceIdentity, store: TrustStore, role: PeerRole, name: String, queue: DispatchQueue) {
  self.stream = stream; self.queue = queue; exchange = LANPairing(identity: identity, store: store, role: role, name: name)
 }
 public func start() {
  keepAlive = self
  exchange.send = { [weak self] data in
   guard let self, !self.closed else { return }; var w = ByteWriter(); w.u16(UInt16(data.count)); w.bytes(data); self.pendingSends += 1
   self.stream.send(w.data) { [weak self] error in self?.queue.async { guard let self else { return }; self.pendingSends -= 1; if error != nil { self.finish(false) }; self.flushClose() } }
  }
  exchange.onPrompt = { [weak self] in self?.onPrompt($0) }; exchange.onComplete = { [weak self] in self?.finish($0) }
  stream.onData = { [weak self] data in self?.queue.async { self?.receive(data) } }
  stream.onClose = { [weak self] _ in self?.queue.async { self?.finish(false) } }
  stream.start(); exchange.start()
  queue.asyncAfter(deadline: .now() + 120) { [weak self] in guard let self, self.completed == nil else { return }; self.finish(false) }
 }
 public func confirm(_ accepted: Bool) { exchange.confirm(accepted) }
 public func cancel() { exchange.cancel(); finish(false) }
 private func receive(_ data: Data) {
  guard !closed, completed == nil else { return }; guard buffer.count + data.count <= 4096 else { return finish(false) }; buffer.append(data)
  while buffer.count >= 2, completed == nil {
   let length = Int(buffer[0]) << 8 | Int(buffer[1]); guard (1...130).contains(length) else { return finish(false) }
   guard buffer.count >= 2 + length else { return }; let payload = Data(buffer[2..<(2+length)]); buffer = Data(buffer.dropFirst(2+length)); exchange.receive(payload)
  }
 }
 private func finish(_ success: Bool) {
  guard completed == nil else { return }; completed = success
  // Keep our final stored receipt alive until Network.framework has accepted it.
  flushClose(); onComplete(success)
 }
 private func flushClose() {
  guard completed != nil, !closed, pendingSends == 0 || completed == false else { return }; closed = true
  stream.onData = nil; stream.onClose = nil; stream.close(); keepAlive = nil
 }
}
