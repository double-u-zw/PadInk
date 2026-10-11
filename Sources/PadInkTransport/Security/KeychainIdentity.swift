import Foundation
import Security
import PadInkCore

/// Stable service + app-specific account survive same-team covering installs; never synchronize.
public enum KeychainIdentity {
 public enum Failure:Error {case status(OSStatus),invalidData}
 private static func query(_ account:String)->[String:Any] {
  var q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:ProductIdentity.keychainService,kSecAttrAccount as String:account,kSecAttrSynchronizable as String:false]
  #if os(macOS)
  // Personal Team's non-sandboxed Mac build has no provisioned access-group entitlement.
  // Use the local login keychain, protected by the stable signing requirement. Never sync.
  q[kSecUseDataProtectionKeychain as String]=false
  #endif
  return q
 }
 static func read(_ account:String)throws->Data? {
  var q=query(account);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
  var value:CFTypeRef?;let s=SecItemCopyMatching(q as CFDictionary,&value)
  if s==errSecItemNotFound{return nil};guard s==errSecSuccess else{throw Failure.status(s)}
  guard let d=value as? Data else{throw Failure.invalidData};return d
 }
 static func write(_ account:String,_ data:Data)throws {
  let q=query(account);let s=SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary)
  if s==errSecItemNotFound {var a=q;a[kSecValueData as String]=data;
   #if !os(macOS)
   a[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
   #endif
   let added=SecItemAdd(a as CFDictionary,nil);guard added==errSecSuccess else{throw Failure.status(added)}}
  else if s != errSecSuccess {throw Failure.status(s)}
 }
 public static func load(account:String = Bundle.main.bundleIdentifier ?? "dev.padink03.development")throws->AttachmentSecurity {
  let identity:DeviceIdentity
  if let data=try read(account+".identity") {identity=try DeviceIdentity(privateKey:data)}
  else {identity=DeviceIdentity();try write(account+".identity",identity.privateKey)}
  let store=try TrustStore(data:read(account+".peers"),save:{try write(account+".peers",$0)})
  return AttachmentSecurity(identity:identity,store:store)
 }
}
