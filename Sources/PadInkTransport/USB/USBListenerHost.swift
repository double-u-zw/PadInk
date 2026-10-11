import Foundation
import Network
import PadInkCore

/// A listener owned by USBListenerHost. Production still binds only the existing loopback port;
/// the protocol permits deterministic lifecycle tests without opening a socket.
public protocol USBListenerInstance: AnyObject {
 var onStream: ((ByteStream) -> Void)? { get set }
 var onState: ((NWListener.State) -> Void)? { get set }
 func start()
 func cancel()
}

private final class LiveUSBListener: USBListenerInstance {
 private let listener: LoopbackListener
 var onStream: ((ByteStream) -> Void)?
 var onState: ((NWListener.State) -> Void)? {
  get { listener.onState }
  set { listener.onState = newValue }
 }
 init(queue: DispatchQueue) throws {
  listener = try LoopbackListener(queue: queue)
  listener.onStream = { [weak self] stream in
   guard let self, let accept = self.onStream else { stream.close(); return }
   accept(stream)
  }
 }
 func start() { listener.start() }
 func cancel() { listener.cancel() }
}

/// Keeps the iPad's USB listener usable across foreground resumes and terminal Network failures.
/// Call start/stop on the owner queue. Stop retires both the listener and its pending retry;
/// callbacks from retired instances never admit a stream or alter the new listener's state.
public final class USBListenerHost {
 public enum State: Equatable {
  case stopped, starting, ready
  case waiting(String)
  case retrying(attempt: Int, delay: TimeInterval, reason: String)
  public var diagnosticCode: String {
   switch self {
   case .stopped: return "stopped"
   case .starting: return "starting"
   case .ready: return "ready"
   case .waiting: return "waiting"
   case .retrying: return "retrying"
   }
  }
  public var errorCode: String? {
   switch self {
   case .waiting(let reason), .retrying(_, _, let reason): return reason
   default: return nil
   }
  }
 }
 public typealias Factory = (DispatchQueue) throws -> USBListenerInstance
 public typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
 public var onStream: (ByteStream) -> Void = { $0.close() }
 public var onState: (State) -> Void = { _ in }
 public private(set) var state: State = .stopped
 private let queue: DispatchQueue, factory: Factory, schedule: Schedule
 private var listener: USBListenerInstance?
 private var enabled = false, retryPending = false, retryAttempt = 0
 private var epoch: UInt64 = 0

 public convenience init(queue: DispatchQueue) {
  self.init(queue: queue, factory: { try LiveUSBListener(queue: $0) })
 }
 public init(queue: DispatchQueue, factory: @escaping Factory, schedule: Schedule? = nil) {
  self.queue = queue; self.factory = factory
  self.schedule = schedule ?? { delay, job in queue.asyncAfter(deadline: .now() + delay, execute: job) }
 }

 public func start() {
  guard !enabled else { return }
  enabled = true; retryAttempt = 0; install()
 }
 public func stop() {
  enabled = false; retryPending = false; retryAttempt = 0; retire()
  publish(.stopped)
 }

 private func install() {
  guard enabled, listener == nil, !retryPending else { return }
  epoch &+= 1; let generation = epoch
  publish(.starting)
  guard enabled, epoch == generation else { return }
  do {
   let instance = try factory(queue); listener = instance
   instance.onStream = { [weak self, weak instance] stream in
    guard let self else { stream.close(); return }
    self.queue.async { [weak self, weak instance] in
     guard let self, let instance, self.enabled, self.epoch == generation,
           self.listener === instance else { stream.close(); return }
     self.onStream(stream)
    }
   }
   instance.onState = { [weak self, weak instance] status in
    self?.queue.async { [weak self, weak instance] in
     guard let self, let instance, self.enabled, self.epoch == generation,
           self.listener === instance else { return }
     switch status {
     case .ready: self.retryAttempt = 0; self.publish(.ready)
     case .waiting(let error): self.publish(.waiting(Self.code(error)))
     case .failed(let error): self.retry(Self.code(error))
     case .cancelled: self.retry("listenerCancelled")
     default: break
     }
    }
   }
   instance.start()
  } catch { retry(Self.code(error)) }
 }
 private func retire() {
  epoch &+= 1
  let old = listener; listener = nil
  old?.onStream = nil; old?.onState = nil; old?.cancel()
 }
 private func retry(_ reason: String) {
  guard enabled, !retryPending else { return }
  retire(); retryPending = true; retryAttempt += 1
  let generation = epoch, delay = min(10.0, 0.5 * pow(2.0, Double(min(retryAttempt - 1, 5))))
  publish(.retrying(attempt: retryAttempt, delay: delay, reason: reason))
  schedule(delay) { [weak self] in
   guard let self, self.enabled, self.epoch == generation, self.retryPending else { return }
   self.retryPending = false; self.install()
  }
 }
 private func publish(_ state: State) { self.state = state; onState(state) }
 /// Stable numeric reason codes, rather than localized error descriptions or endpoint text.
 private static func code(_ error: Error) -> String {
  if let network = error as? NWError {
   if case .posix(let code) = network { return "posix_\(code.rawValue)" }
   if case .dns(let code) = network { return "dns_\(code)" }
   if case .tls(let code) = network { return "tls_\(code)" }
   return "networkUnknown"
  }
  return "listenerCreation_\((error as NSError).code)"
 }
 deinit { listener?.onStream = nil; listener?.onState = nil; listener?.cancel() }
}
