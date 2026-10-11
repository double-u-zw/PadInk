import Foundation

/// One ordered, reliable byte stream (a TCP connection through usbmuxd, a Network.framework
/// connection, or FakeStream in tests). The only transport abstraction (REWRITE_BRIEF §4.4):
/// three implementations exist. Callbacks may arrive on any queue; owners hop to their own.
public protocol ByteStream: AnyObject {
 var onData: ((Data) -> Void)? { get set }
 /// Called once, with nil for an orderly close.
 var onClose: ((Error?) -> Void)? { get set }
 func start()
 /// Completion fires when the bytes left PadInk's queue (handed to the OS or the peer).
 func send(_ data: Data, completion: @escaping (Error?) -> Void)
 func close()
 /// Bytes accepted by send() whose completion has not fired yet.
 var queuedBytes: Int { get }
}

public enum StreamError: Error, Equatable { case closed, failed(String) }

/// In-memory stream pair for deterministic tests (REWRITE_BRIEF §11.2: delay, stall, disconnect,
/// reconnect). Delivery happens asynchronously on one shared serial queue; `settle()` waits for it.
public final class FakeStream: ByteStream {
 public var onData: ((Data) -> Void)?
 public var onClose: ((Error?) -> Void)?
 private let lock = NSLock(), delivery: DispatchQueue
 private weak var peer: FakeStream?
 private var held = [(Data, (Error?) -> Void)](), stalled = false, closed = false
 public private(set) var sentFrames = 0
 private init(delivery: DispatchQueue) { self.delivery = delivery }

 public static func pair(label: String = "fake.stream") -> (FakeStream, FakeStream) {
  let q = DispatchQueue(label: label); let a = FakeStream(delivery: q), b = FakeStream(delivery: q)
  a.peer = b; b.peer = a; return (a, b)
 }
 public func start() {}
 public var queuedBytes: Int { lock.lock(); defer { lock.unlock() }; return held.reduce(0) { $0 + $1.0.count } }
 public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

 public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
  lock.lock()
  if closed { lock.unlock(); delivery.async { completion(StreamError.closed) }; return }
  sentFrames += 1
  if stalled { held.append((data, completion)); lock.unlock(); return }
  lock.unlock(); deliver(data, completion)
 }
 private func deliver(_ data: Data, _ completion: @escaping (Error?) -> Void) {
  delivery.async { [peer] in
   guard let peer, !peer.isClosed else { completion(StreamError.closed); return }
   completion(nil); peer.onData?(data)
  }
 }
 /// Sender-side stall: bytes queue up and completions do not fire (a congested or dead path).
 public func stall() { lock.lock(); stalled = true; lock.unlock() }
 /// Release held bytes in order.
 public func resume() { lock.lock(); stalled = false; let pending = held; held.removeAll(); lock.unlock(); pending.forEach { deliver($0.0, $0.1) } }
 /// Release only the oldest held chunk (slow drain).
 public func drainOne() { lock.lock(); guard !held.isEmpty else { lock.unlock(); return }; let first = held.removeFirst(); lock.unlock(); deliver(first.0, first.1) }

 public func close() { finish(nil, notifyPeer: true) }
 /// Abrupt failure on both ends (cable pulled).
 public func fail(_ reason: String = "fake failure") { finish(StreamError.failed(reason), notifyPeer: true) }
 private func finish(_ error: Error?, notifyPeer: Bool) {
  lock.lock(); guard !closed else { lock.unlock(); return }; closed = true; let pending = held; held.removeAll(); lock.unlock()
  delivery.async { [weak self] in
   pending.forEach { $0.1(StreamError.closed) }
   let callback = self?.onClose; self?.onClose = nil; callback?(error)
   if notifyPeer, let peer = self?.peer { peer.finish(error, notifyPeer: false) }
  }
 }
 /// Wait until every scheduled delivery has run.
 public func settle() { delivery.sync {} }
}
