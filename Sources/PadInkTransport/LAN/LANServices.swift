import Foundation
import Network
import PadInkCore

public struct LANPeer {
 public let id: Data, endpoint: NWEndpoint, pairingEndpoint: NWEndpoint?, name: String
}

/// One Bonjour service advertises the TLS product port; a temporary pairing-only port is in TXT.
/// Pairing listener exists only during an explicit 120-second window, and admits one attempt.
public final class LANServiceHost {
 public var onStream: (NWStream) -> Void = { _ in }, onStatus: (String) -> Void = { _ in }
 public var onPairPrompt: (LANPairingPrompt?) -> Void = { _ in }, onPaired: () -> Void = {}
 private let security: AttachmentSecurity, queue: DispatchQueue, name: String
 private var listener: NWListener?, pairingListener: NWListener?, pairing: LANPairingSocket?
 private var retryAttempt = 0
 private var keySignature = "", pairPort: UInt16?, epoch: UInt64 = 0, pairingEpoch: UInt64 = 0, acceptingPair = false
 public init(security: AttachmentSecurity, name: String, queue: DispatchQueue) { self.security = security; self.name = String(name.prefix(64)); self.queue = queue }
 public func refreshKeys() {
  let peers = security.store.peers.sorted { $0.id < $1.id }, signature = peers.map { $0.id }.joined(separator: ",")
  guard listener == nil || signature != keySignature else { return }; keySignature = signature
  epoch += 1; let generation = epoch; listener?.cancel()
  do {
   var keys = peers.map { (LANKeys.label(local: security.identity.id, peer: $0.deviceID), LANKeys.tlsKey($0.pairKey)) }
   if keys.isEmpty { keys = [("unpaired", LogicalSession.newToken())] } // Unpublished random key: no product admission.
   let l = try NWListener(using: LANTLS.parameters(keys: keys)); listener = l
   l.newConnectionHandler = { [weak self] c in guard let self, self.epoch == generation else { c.cancel(); return }; let s = NWStream(c, queue: self.queue); s.readyCheck = LANTLS.confirmed; self.onStream(s) }
   l.stateUpdateHandler = { [weak self] state in guard let self, self.epoch == generation else { return }; switch state {
    case .ready: self.retryAttempt = 0; self.onStatus("Wi-Fi 等待连接")
    case .waiting: self.onStatus("Wi-Fi 等待网络或本地网络授权")
    case .failed:
     self.onStatus("Wi-Fi 服务不可用，请检查本地网络权限或使用 USB")
     self.listener?.cancel(); self.listener = nil; self.retryAttempt += 1
     let delay = min(10.0, 0.5 * pow(2.0, Double(min(self.retryAttempt - 1, 5))))
     self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in guard let self, self.epoch == generation else { return }; self.refreshKeys() }
    default: break
   } }
   advertise(); l.start(queue: queue)
  } catch { listener = nil; onStatus("Wi-Fi 安全服务无法启动") }
 }
 private func advertise() {
  var txt = ["name": Data(name.utf8)]
  if let pairPort { txt["pair"] = Data(String(pairPort).utf8) }
  var service = NWListener.Service(name: LANKeys.serviceName(security.identity.id), type: ProductIdentity.bonjourServiceType, txtRecord: NetService.data(fromTXTRecord: txt)); service.noAutoRename = true; listener?.service = service
 }
 public func beginPairing() {
  endPairing(); pairingEpoch += 1; let generation = pairingEpoch; acceptingPair = true
  do {
   let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; let p = NWParameters(tls: nil, tcp: tcp); p.includePeerToPeer = false
   let l = try NWListener(using: p); pairingListener = l
   l.stateUpdateHandler = { [weak self, weak l] state in guard let self, self.pairingEpoch == generation else { return }; if case .ready = state { self.pairPort = l?.port?.rawValue; self.advertise(); self.onStatus("请在 Mac 的 PadInk 菜单选择这台 iPad，配对窗口 120 秒") } }
   l.newConnectionHandler = { [weak self] c in
    guard let self, self.pairingEpoch == generation, self.acceptingPair else { c.cancel(); return }; self.acceptingPair = false
    let socket = LANPairingSocket(stream: NWStream(c, queue: self.queue), identity: self.security.identity, store: self.security.store, role: .ipad, name: self.name, queue: self.queue); self.pairing = socket
    socket.onPrompt = { [weak self] prompt in self?.onPairPrompt(prompt) }
    socket.onComplete = { [weak self] success in
     guard let self, self.pairingEpoch == generation else { return }
     self.endPairing(); if success { self.security.onChange?(); self.refreshKeys(); self.onPaired() }; self.onStatus(success ? "Wi-Fi 配对已保存" : "配对未完成，请重新打开配对窗口")
    }; socket.start()
   }
   l.start(queue: queue)
   queue.asyncAfter(deadline: .now() + 120) { [weak self] in guard let self, self.pairingEpoch == generation else { return }; self.endPairing(); self.onStatus("Wi-Fi 配对窗口已结束") }
  } catch { endPairing(); onStatus("Wi-Fi 配对服务无法启动") }
 }
 public func confirmPairing(_ accepted: Bool) { pairing?.confirm(accepted) }
 public func endPairing() {
  pairingEpoch += 1; acceptingPair = false; pairing?.cancel(); pairing = nil; pairingListener?.cancel(); pairingListener = nil; pairPort = nil; onPairPrompt(nil); advertise()
 }
 public func stop() { endPairing(); epoch += 1; listener?.cancel(); listener = nil }
}

/// Bonjour browse plus Foundation's resolver (main run loop) to use a temporary pairing port on
/// the same resolved host. Product TLS keys, not untrusted TXT/name/address data, authenticate it.
public final class LANDiscovery: NSObject, NetServiceDelegate {
 public var onUpdate: ([LANPeer]) -> Void = { _ in }, onStatus: (String) -> Void = { _ in }
 private let queue: DispatchQueue
 private var browser: NWBrowser?, epoch: UInt64 = 0
 private var services: [String: NetService] = [:], resolved: [String: LANPeer] = [:]
 public init(queue: DispatchQueue) { self.queue = queue }
 public func start() { DispatchQueue.main.async { [weak self] in self?.startMain() } }
 private func startMain() {
  stopMain(); let generation = epoch
  let p = NWParameters.tcp; p.includePeerToPeer = false
  let b = NWBrowser(for: .bonjourWithTXTRecord(type: ProductIdentity.bonjourServiceType, domain: nil), using: p); browser = b
  b.stateUpdateHandler = { [weak self] state in guard let self, self.epoch == generation else { return }; switch state {
   case .waiting(let error): if case .dns(let code) = error, code == -65570 { self.status("本地网络权限被拒绝，请在系统设置中允许 PadInk") } else { self.status("Wi-Fi 等待网络；可先使用 USB") }
   case .failed: self.status("Wi-Fi 发现失败，请检查本地网络权限和网络隔离设置")
   default: break
  } }
  b.browseResultsChangedHandler = { [weak self] results, _ in
   guard let self, self.epoch == generation else { return }
   let names = results.compactMap { result -> (String,String,String)? in guard case .service(let name, let type, let domain, _) = result.endpoint, LANKeys.deviceID(name) != nil else { return nil }; return (name,type,domain) }
   DispatchQueue.main.async { [weak self] in
    guard let self, self.epoch == generation else { return }
    let valid = Set(names.map { $0.0 })
    for key in Array(self.services.keys) where !valid.contains(key) { self.services.removeValue(forKey: key)?.stop(); self.resolved.removeValue(forKey: key) }
    for (name,type,domain) in names {
     if let service = self.services[name] { service.stop(); service.resolve(withTimeout: 5) }
     else { let service = NetService(domain: domain, type: type, name: name); service.delegate = self; self.services[name] = service; service.resolve(withTimeout: 5) }
    }
    self.publish()
   }
  }; b.start(queue: .main)
  DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
   guard let self, self.epoch == generation, self.resolved.isEmpty else { return }
   self.status("未发现 iPad。请确认两端应用已打开、允许本地网络并连接同一网络；若当前网络不允许设备互连，请使用 USB。")
  }
 }
 public func stop() { DispatchQueue.main.async { [weak self] in self?.stopMain() } }
 private func stopMain() {
  epoch += 1; browser?.cancel(); browser = nil
  services.values.forEach { $0.stop() }; services.removeAll(); resolved.removeAll(); publish()
 }
 private func status(_ message: String) { queue.async { [weak self] in self?.onStatus(message) } }
 private func publish() { let peers = Array(resolved.values); queue.async { [weak self] in self?.onUpdate(peers) } }
 public func netServiceDidResolveAddress(_ sender: NetService) {
  guard services[sender.name] === sender, let id = LANKeys.deviceID(sender.name), let host = sender.hostName, sender.port > 0, sender.port <= 65535 else { return }
  let txt = sender.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
  let pair = txt["pair"].flatMap { String(data: $0, encoding: .utf8) }.flatMap(UInt16.init)
  let name = String((txt["name"].flatMap { String(data: $0, encoding: .utf8) } ?? "iPad").prefix(64))
  let address = NWEndpoint.Host(host)
  resolved[sender.name] = LANPeer(id: id, endpoint: .hostPort(host: address, port: NWEndpoint.Port(rawValue: UInt16(sender.port))!), pairingEndpoint: pair.flatMap { $0 > 0 ? .hostPort(host: address, port: NWEndpoint.Port(rawValue: $0)!) : nil }, name: name); publish()
 }
 public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { guard services[sender.name] === sender else { return }; resolved.removeValue(forKey: sender.name); publish() }
}
