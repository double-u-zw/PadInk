import XCTest
import Foundation
import Network
import PadInkCore
@testable import PadInkTransport

final class USBListenerHostTests: XCTestCase {
 private final class Listener: USBListenerInstance {
  var onStream: ((ByteStream) -> Void)?, onState: ((NWListener.State) -> Void)?
  var starts = 0, cancels = 0, callbacksClearedAtCancel = false
  func start() { starts += 1 }
  func cancel() {
   cancels += 1; callbacksClearedAtCancel = onStream == nil && onState == nil
   onState?(.cancelled)
  }
 }
 private final class Fixture {
  let queue = DispatchQueue(label: "test.usb.listener")
  var instances: [Listener] = [], jobs: [(TimeInterval, () -> Void)] = [], states: [USBListenerHost.State] = []
  var accepted: [ByteStream] = [], failures = 0
  lazy var host: USBListenerHost = {
   let h = USBListenerHost(queue: queue, factory: { [unowned self] _ in
    if failures > 0 { failures -= 1; throw NSError(domain: "test", code: 99) }
    let l = Listener(); instances.append(l); return l
   }, schedule: { [unowned self] delay, job in jobs.append((delay, job)) })
   h.onStream = { [unowned self] in accepted.append($0) }
   h.onState = { [unowned self] in states.append($0) }; return h
  }()
  func start() { queue.sync { host.start() }; settle() }
  func stop() { queue.sync { host.stop() }; settle() }
  func settle() { queue.sync {} }
  func retry() { queue.sync { jobs.removeFirst().1() }; settle() }
 }

 func testFailedListenerIsRetiredThenRecreatedWithBoundedBackoff() {
  let f = Fixture(); f.start(); XCTAssertEqual(f.instances.count, 1)
  for attempt in 1...8 {
   let current = f.instances.last!; current.onState?(.failed(.posix(.ECONNABORTED))); f.settle()
   XCTAssertEqual(current.cancels, 1); XCTAssertTrue(current.callbacksClearedAtCancel)
   XCTAssertEqual(f.jobs.count, 1)
   let delay = min(10, 0.5 * pow(2, Double(min(attempt - 1, 5))))
   XCTAssertEqual(f.jobs[0].0, delay)
   XCTAssertEqual(f.host.state, .retrying(attempt: attempt, delay: delay, reason: "posix_53"))
   f.retry(); XCTAssertEqual(f.instances.count, attempt + 1)
  }
  f.instances.last!.onState?(.ready); f.settle(); XCTAssertEqual(f.host.state, .ready)
  f.instances.last!.onState?(.failed(.posix(.ECONNABORTED))); f.settle()
  XCTAssertEqual(f.jobs.first?.0, 0.5, "a usable listener resets failure backoff")
  f.stop()
 }
 func testTerminalFailureSchedulesRecoveryRatherThanLeavingDeadListener() throws {
  let f = Fixture(); f.start(); defer { f.stop() }
  f.instances[0].onState?(.failed(.posix(.ECONNABORTED))); f.settle()
  XCTAssertEqual(f.host.state.diagnosticCode, "retrying")
  _ = try XCTUnwrap(f.jobs.first, "terminal failure must schedule recovery without requiring app restart")
  f.retry(); XCTAssertEqual(f.instances.count, 2)
  f.instances.last?.onState?(.ready); f.settle(); XCTAssertEqual(f.host.state, .ready)
 }
 func testForegroundRecreatesCancelledListenerRatherThanRetainingDeadInstance() {
  let f = Fixture(); f.start(); f.stop(); f.start(); defer { f.stop() }
  XCTAssertEqual(f.instances.count, 2, "foreground must own a newly started listener")
  guard let current = f.instances.last else { return XCTFail("missing listener") }
  XCTAssertEqual(current.starts, 1); XCTAssertEqual(current.cancels, 0)
 }
 func testWaitingCanRecoverWithoutDestroyingListener() {
  let f = Fixture(); f.start(); let listener = f.instances[0]
  listener.onState?(.waiting(.posix(.ENETDOWN))); f.settle()
  XCTAssertEqual(f.host.state, .waiting("posix_50")); XCTAssertTrue(f.jobs.isEmpty); XCTAssertEqual(listener.cancels, 0)
  listener.onState?(.ready); f.settle()
  XCTAssertEqual(f.host.state, .ready); XCTAssertEqual(f.instances.count, 1); f.stop()
 }
 func testUnexpectedCancellationAndConstructionFailureRetry() {
  let f = Fixture(); f.failures = 1; f.start()
  XCTAssertEqual(f.host.state, .retrying(attempt: 1, delay: 0.5, reason: "listenerCreation_99"))
  XCTAssertTrue(f.instances.isEmpty); f.retry()
  f.instances[0].onState?(.cancelled); f.settle()
  XCTAssertEqual(f.host.state, .retrying(attempt: 2, delay: 1, reason: "listenerCancelled"))
  f.retry(); XCTAssertEqual(f.instances.count, 2); f.stop()
 }
 func testForegroundRestartsListenerAndRejectsRetiredStreamAndStateCallbacks() throws {
  let f = Fixture(); f.start(); let old = f.instances[0]
  let oldStream = try XCTUnwrap(old.onStream), oldState = try XCTUnwrap(old.onState)
  f.stop(); XCTAssertTrue(old.callbacksClearedAtCancel); XCTAssertEqual(old.cancels, 1)
  f.start(); let current = f.instances[1]
  current.onState?(.ready); f.settle()
  let stale = FakeStream.pair().0
  oldStream(stale); oldState(.failed(.posix(.ECONNABORTED))); oldState(.ready); f.settle()
  XCTAssertTrue(stale.isClosed); XCTAssertEqual(f.host.state, .ready); XCTAssertTrue(f.jobs.isEmpty)
  XCTAssertEqual(current.cancels, 0); XCTAssertTrue(f.accepted.isEmpty)
  let fresh = FakeStream.pair().0; current.onStream?(fresh); f.settle()
  XCTAssertEqual(f.accepted.count, 1); XCTAssertTrue(f.accepted[0] === fresh); fresh.close(); f.stop()
 }
 func testAlreadyQueuedOldStreamIsClosedAfterStopBeforeCallbackExecution() throws {
  let f = Fixture(); f.start(); let callback = try XCTUnwrap(f.instances[0].onStream)
  let stale = FakeStream.pair().0
  f.queue.sync { callback(stale); f.host.stop() }; f.settle()
  XCTAssertTrue(stale.isClosed); XCTAssertTrue(f.accepted.isEmpty); XCTAssertEqual(f.host.state, .stopped)
 }
 func testStopInvalidatesPendingRetryAndDoesNotRestartInBackground() {
  let f = Fixture(); f.start(); f.instances[0].onState?(.failed(.posix(.ECONNABORTED))); f.settle()
  XCTAssertEqual(f.jobs.count, 1); f.stop(); f.retry()
  XCTAssertEqual(f.host.state, .stopped); XCTAssertEqual(f.instances.count, 1)
  f.start(); XCTAssertEqual(f.instances.count, 2); f.stop()
 }
 func testOldFailureRetryCannotTouchListenerCreatedByNewForeground() {
  let f = Fixture(); f.start(); f.instances[0].onState?(.failed(.posix(.ECONNABORTED))); f.settle()
  f.stop(); f.start(); let current = f.instances[1]
  current.onState?(.ready); f.settle(); f.retry()
  XCTAssertEqual(f.host.state, .ready); XCTAssertEqual(f.instances.count, 2); XCTAssertEqual(current.cancels, 0)
  f.stop()
 }
 func testStartIsIdempotentAndHostCanReleaseWithScheduledRetry() {
  let q = DispatchQueue(label: "test.usb.listener.release")
  var jobs: [() -> Void] = [], instances: [Listener] = []
  var host: USBListenerHost? = USBListenerHost(queue: q, factory: { _ in let l = Listener(); instances.append(l); return l }, schedule: { _, job in jobs.append(job) })
  weak var weakHost = host
  q.sync { host!.start(); host!.start() }; q.sync {}
  XCTAssertEqual(instances.count, 1); XCTAssertEqual(instances[0].starts, 1)
  instances[0].onState?(.failed(.posix(.ECONNABORTED))); q.sync {}
  XCTAssertEqual(jobs.count, 1)
  q.sync { host = nil }; XCTAssertNil(weakHost)
  q.sync { jobs.removeFirst()() }; XCTAssertEqual(instances.count, 1)
 }
 func testStateDiagnosticsUseStableCodesWithoutErrorDescriptions() {
  XCTAssertEqual(USBListenerHost.State.waiting("posix_50").diagnosticCode, "waiting")
  XCTAssertEqual(USBListenerHost.State.retrying(attempt: 1, delay: 0.5, reason: "dns_-65570").errorCode, "dns_-65570")
  XCTAssertNil(USBListenerHost.State.ready.errorCode)
 }
}

final class USBListenerLoopbackRecoveryTests: XCTestCase {
 private final class RealListener: USBListenerInstance {
  let listener: LoopbackListener
  var onStream: ((ByteStream) -> Void)?
  var onState: ((NWListener.State) -> Void)? { get { listener.onState } set { listener.onState = newValue } }
  init(port: UInt16, queue: DispatchQueue) throws {
   listener = try LoopbackListener(port: port, queue: queue)
   listener.onStream = { [weak self] stream in
    guard let accept = self?.onStream else { stream.close(); return }; accept(stream)
   }
  }
  func start() { listener.start() }
  func cancel() { listener.cancel() }
 }
 func testRealLoopbackAcceptsAndResumesOnSamePort() throws {
  let q = DispatchQueue(label: "test.usb.listener.real")
  var listeners: [RealListener] = [], port: UInt16 = 0
  let host = USBListenerHost(queue: q, factory: { queue in let l = try RealListener(port: port, queue: queue); listeners.append(l); return l })
  var ready = expectation(description: "initial listener ready")
  host.onState = { if case .ready = $0 { ready.fulfill() } }
  q.sync { host.start() }; wait(for: [ready], timeout: 3)
  port = try XCTUnwrap(listeners[0].listener.port)
  var server: ByteStream?, client: NWStream?
  defer { q.sync { client?.close(); server?.close(); host.stop() } }
  func exchange(_ message: String) {
   let accepted = expectation(description: "accepted loopback"), echoed = expectation(description: "echoed payload")
   q.sync {
    host.onStream = { stream in
     server = stream; stream.onData = { data in stream.send(data) { XCTAssertNil($0) } }; stream.start(); accepted.fulfill()
    }
    let stream = NWStream(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp), queue: q); client = stream
    stream.onData = { XCTAssertEqual($0, Data(message.utf8)); echoed.fulfill() }; stream.start(); stream.send(Data(message.utf8)) { XCTAssertNil($0) }
   }
   wait(for: [accepted, echoed], timeout: 3)
   q.sync { client?.close(); server?.close(); client = nil; server = nil }
  }
  exchange("before background")
  q.sync { host.stop() }
  ready = expectation(description: "resumed listener ready")
  q.sync { host.start() }; wait(for: [ready], timeout: 3)
  // Network cancellation closes asynchronously: an immediate same-port bind may need one retry.
  XCTAssertGreaterThanOrEqual(listeners.count, 2); XCTAssertEqual(listeners.last?.listener.port, port)
  exchange("after foreground")
 }
}
