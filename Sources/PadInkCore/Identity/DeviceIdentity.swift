import Foundation
import CryptoKit

public struct DeviceIdentity {
 private let key: Curve25519.KeyAgreement.PrivateKey
 public init() { key = .init() }
 public init(privateKey: Data) throws { key = try .init(rawRepresentation: privateKey) }
 public var privateKey: Data { key.rawRepresentation }
 public var publicKey: Data { key.publicKey.rawRepresentation }
 public var id: Data { Self.id(publicKey: publicKey) }
 public static func id(publicKey: Data) -> Data { Data(SHA256.hash(data: publicKey)) }
 public func pairKey(with publicKey: Data) throws -> Data {
  let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
  let ids = [id, Self.id(publicKey: publicKey)].sorted { $0.lexicographicallyPrecedes($1) }
  let secret = try key.sharedSecretFromKeyAgreement(with: peer)
  let derived = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ids[0]+ids[1], sharedInfo: Data("PadInk pair key v1".utf8), outputByteCount: 32)
  return derived.withUnsafeBytes { Data($0) }
 }
}

public struct TrustedPeer: Codable, Equatable, Identifiable {
 public let deviceID: Data, publicKey: Data, pairKey: Data
 public var name: String
 public var id: String { deviceID.map { String(format:"%02x",$0) }.joined() }
 public init(publicKey:Data,pairKey:Data,name:String) { self.publicKey=publicKey;deviceID=DeviceIdentity.id(publicKey:publicKey);self.pairKey=pairKey;self.name=String(name.prefix(64)) }
}
/// Queue-confined, with transactional persistence. A failed Keychain write cannot create trust.
public final class TrustStore {
 public private(set) var peers:[TrustedPeer]
 private let save:(Data)throws->Void
 public init(data:Data?=nil,save:@escaping(Data)throws->Void={_ in})throws {
  peers = try data.map { try JSONDecoder().decode([TrustedPeer].self,from:$0) } ?? []
  guard peers.count <= 32, Set(peers.map(\.id)).count == peers.count,peers.allSatisfy({$0.publicKey.count==32 && $0.pairKey.count==32 && $0.deviceID==DeviceIdentity.id(publicKey:$0.publicKey)}) else {throw PayloadError.value}
  self.save=save
 }
 public func peer(_ id:Data)->TrustedPeer? { peers.first{$0.deviceID==id} }
 public func put(_ peer:TrustedPeer)throws { guard peer.publicKey.count == 32, peer.pairKey.count == 32, peer.deviceID == DeviceIdentity.id(publicKey: peer.publicKey) else { throw PayloadError.value }; if peers.contains(peer) { return }; var next=peers.filter{$0.deviceID != peer.deviceID};next.append(peer);guard next.count <= 32 else { throw PayloadError.value };try save(JSONEncoder().encode(next));peers=next }
 public func remove(_ id:Data)throws {let next=peers.filter{$0.deviceID != id};try save(JSONEncoder().encode(next));peers=next}
}

public struct PairingRequest: Equatable, Identifiable {
 public let deviceID:Data,name:String
 public var id:String { deviceID.base64EncodedString() }
 public init(deviceID: Data, name: String) { self.deviceID = deviceID; self.name = name }
}
/// Shared by A and B on the coordinator queue; one UI confirmation per peer, on each device.
public final class AttachmentSecurity {
 public let identity:DeviceIdentity, store:TrustStore
 public var onChange:(()->Void)?
 public private(set) var requests:[PairingRequest]=[]
 private var callbacks:[Data:[UUID:(Bool)->Void]]=[:], decisions:[Data:Bool]=[:]
 public init(identity:DeviceIdentity,store:TrustStore) {self.identity=identity;self.store=store}
 func request(_ peer:Hello,token:UUID,completion:@escaping(Bool)->Void) {
  if store.peer(peer.deviceID) != nil {completion(true);return}
  if let accepted=decisions[peer.deviceID] {completion(accepted);return}
  callbacks[peer.deviceID,default:[:]][token]=completion
  if !requests.contains(where:{$0.deviceID==peer.deviceID}) {requests.append(PairingRequest(deviceID:peer.deviceID,name:peer.displayName));onChange?()}
 }
 func withdraw(_ token:UUID) {
  for id in Array(callbacks.keys) {callbacks[id]?.removeValue(forKey:token);if callbacks[id]?.isEmpty == true {callbacks.removeValue(forKey:id);requests.removeAll{$0.deviceID==id}}};onChange?()
 }
 public func confirm(_ id:Data,accepted:Bool) {
  guard let pending=callbacks.removeValue(forKey:id) else{return}
  decisions[id]=accepted;requests.removeAll{$0.deviceID==id};pending.values.forEach{$0(accepted)};onChange?()
 }
 public func forget(_ id:Data)throws {try store.remove(id);decisions[id]=false;if callbacks[id] != nil {confirm(id,accepted:false)};onChange?()}
 public func allowNewPairing() {decisions.removeAll()}
}
