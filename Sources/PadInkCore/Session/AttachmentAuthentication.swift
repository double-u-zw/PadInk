import Foundation
import CryptoKit

/// Mutual proof over ordered HELLOs, fresh per-stream nonces, roles, A/B, generation and resume token.
/// No input/video is released until both proofs and both authenticated acknowledgements succeed.
final class AttachmentAuthentication {
 let context:AttachmentSecurity, local:Hello, peer:Hello
 private let nonce=LogicalSession.newToken(), token=UUID()
 private var peerNonce:Data?, publicKey:Data?, key:Data?, proof:Data?
 private var approved=false, proofSent=false, peerProven=false, finished=false
 private let send:(MessageType,Data)->Void, complete:(Bool)->Void
 init(context:AttachmentSecurity,local:Hello,peer:Hello,send:@escaping(MessageType,Data)->Void,complete:@escaping(Bool)->Void) {
  self.context=context;self.local=local;self.peer=peer;self.send=send;self.complete=complete
 }
 func start() {send(.authProof,Data([1])+context.identity.publicKey+nonce)}
 func cancel() {finished=true;context.withdraw(token)}
 func receive(_ type:MessageType,_ data:Data) {
  guard !finished else{return}
  if type == .authProof {
   if data.count == 65,data.first == 1 {
    guard peerNonce == nil else{return fail()}
    let pub=Data(data[1..<33]);guard DeviceIdentity.id(publicKey:pub)==peer.deviceID,peer.deviceID != context.identity.id else{return fail()}
    publicKey=pub;peerNonce=Data(data[33..<65])
    do {key = try context.store.peer(peer.deviceID)?.pairKey ?? context.identity.pairKey(with:pub)} catch {return fail()}
    context.request(peer,token:token) { [weak self] yes in
     guard let self,!self.finished else{return};guard yes else{return self.fail()};self.approved=true;self.proofSent=true
     self.send(.authProof,Data([2])+self.tag(role:self.local.role,label:"proof"));self.verifyPeer()
    }
   } else if data.count == 33,data.first == 2 {
    guard peerNonce != nil,proof == nil else{return fail()};proof=Data(data.dropFirst());verifyPeer()
   } else {fail()}
  } else if type == .authResult {
   guard data.count==32,approved,proofSent,peerProven,valid(data,role:peer.role,label:"accepted") else{return fail()}
   finished=true;context.withdraw(token);complete(true)
  } else {fail()}
 }
 private func verifyPeer() {
  guard approved,let proof,!peerProven else{return}
  guard valid(proof,role:peer.role,label:"proof"),let publicKey,let key else{return fail()}
  do {try context.store.put(TrustedPeer(publicKey:publicKey,pairKey:key,name:peer.displayName))} catch {return fail()}
  peerProven=true;context.onChange?();send(.authResult,tag(role:local.role,label:"accepted"))
 }
 private func transcript(role:PeerRole,label:String)->Data {
  guard let peerNonce else{return Data()}
  // HELLO encoding has already succeeded and been validated before this object is made.
  let mac = local.role == .mac ? local:peer, ipad = local.role == .ipad ? local:peer
  let mn = local.role == .mac ? nonce:peerNonce, pn = local.role == .ipad ? nonce:peerNonce
  return Data("PadInk auth v1\0\(label)\0".utf8)+Data([role.rawValue])+(try! mac.encoded())+(try! ipad.encoded())+mn+pn
 }
 private func tag(role:PeerRole,label:String)->Data {Data(HMAC<SHA256>.authenticationCode(for:transcript(role:role,label:label),using:SymmetricKey(data:key!)))}
 private func valid(_ tag:Data,role:PeerRole,label:String)->Bool {guard let key else{return false};return HMAC<SHA256>.isValidAuthenticationCode(tag,authenticating:transcript(role:role,label:label),using:SymmetricKey(data:key))}
 private func fail() {guard !finished else{return};finished=true;context.withdraw(token);complete(false)}
}
