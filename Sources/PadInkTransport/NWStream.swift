import Foundation
import Network
import PadInkCore

/// ByteStream over an NWConnection (iPad loopback listener today; Wi-Fi in Phase 5).
/// Ported from Baseline NetworkChannel, plus queued-byte accounting for AttachmentLiveness.
public final class NWStream: ByteStream {
 public var onData: ((Data) -> Void)?, onClose: ((Error?) -> Void)?
 public var readyCheck: ((NWConnection) -> Bool)?
 public let connection: NWConnection
 private let queue: DispatchQueue, lock = NSLock()
 private var closed = false, queued = 0
 public init(_ connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }
 public var queuedBytes: Int { lock.lock(); defer { lock.unlock() }; return queued }
 public func start() {
  connection.stateUpdateHandler = { [weak self] s in guard let self else { return }; switch s { case .ready: if self.readyCheck?(self.connection) == false { self.finish(StreamError.failed("tlsNegotiation")) } else { self.read() }; case .waiting(let e), .failed(let e): self.finish(e); case .cancelled: self.finish(nil); default: break } }
  connection.start(queue: queue)
 }
 private func read() {
  connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
   guard let self, !self.isClosed else { return }
   if let data, !data.isEmpty { self.onData?(data) }
   if done || error != nil { self.finish(error) } else { self.read() }
  }
 }
 private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
 public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
  lock.lock(); guard !closed else { lock.unlock(); completion(StreamError.closed); return }; queued += data.count; lock.unlock()
  connection.send(content: data, completion: .contentProcessed { [weak self] error in
   if let self { self.lock.lock(); self.queued -= data.count; self.lock.unlock() }
   completion(error)
  })
 }
 public func close() { finish(nil) }
 private func finish(_ error: Error?) {
  lock.lock(); guard !closed else { lock.unlock(); return }; closed = true; lock.unlock()
  connection.cancel(); let callback = onClose; onClose = nil; onData = nil; callback?(error)
 }
}

/// iPad side of the USB transport: usbmuxd delivers Mac connections to this loopback port.
/// Only loopback peers are accepted; the protocol layer identifies A and B by their HELLO.
public final class LoopbackListener {
 public var onStream: ((NWStream) -> Void)?, onState: ((NWListener.State) -> Void)?
 private let listener: NWListener, queue: DispatchQueue
 public var port: UInt16? { listener.port?.rawValue }
 public init(port: UInt16 = ProductIdentity.usbLoopbackPort, queue: DispatchQueue) throws {
  let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
  let parameters = NWParameters(tls: nil, tcp: tcp)
  parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
  parameters.allowLocalEndpointReuse = true
  listener = try NWListener(using: parameters); self.queue = queue
 }
 public func start() {
  listener.newConnectionHandler = { [weak self] c in
   guard let self else { c.cancel(); return }
   guard case .hostPort(let host, _) = c.endpoint, host == NWEndpoint.Host("127.0.0.1") || host == NWEndpoint.Host("::1") else { c.cancel(); return }
   self.onStream?(NWStream(c, queue: self.queue))
  }
  listener.stateUpdateHandler = { [weak self] s in self?.onState?(s) }
  listener.start(queue: queue)
 }
 public func cancel() { listener.cancel() }
}
