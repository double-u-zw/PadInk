#if os(macOS)
import Foundation
import Darwin
import PadInkCore

/// ByteStream over a connected POSIX stream fd (usbmuxd tunnel). Ported from Baseline
/// SocketChannel: one blocking reader, one serial writer, shutdown() unblocks both.
public final class FDStream: ByteStream {
 private var dataHandler: ((Data) -> Void)?, closeHandler: ((Error?) -> Void)?
 public var onData: ((Data) -> Void)? { get { lock.lock(); defer { lock.unlock() }; return dataHandler } set { lock.lock(); dataHandler = newValue; lock.unlock() } }
 public var onClose: ((Error?) -> Void)? { get { lock.lock(); defer { lock.unlock() }; return closeHandler } set { lock.lock(); closeHandler = newValue; lock.unlock() } }
 private let fd: Int32, readQueue = DispatchQueue(label: "pnk2.usb.read", qos: .userInteractive), writeQueue = DispatchQueue(label: "pnk2.usb.write", qos: .userInteractive), group = DispatchGroup(), lock = NSLock()
 private var closed = false, started = false, queued = 0
 /// Sets SO_NOSIGPIPE itself: a write after the peer or shutdown() closed the socket must fail with
 /// EPIPE, never kill the app with SIGPIPE.
 public init(fd: Int32) { self.fd = fd; var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
 public var queuedBytes: Int { lock.lock(); defer { lock.unlock() }; return queued }

 public func start() {
  lock.lock(); guard !started, !closed else { lock.unlock(); return }; started = true; group.enter(); lock.unlock()
  readQueue.async { [self] in defer { group.leave() }; var bytes = [UInt8](repeating: 0, count: 65536)
   while true {
    lock.lock(); let stop = closed; lock.unlock(); if stop { break }
    let n = Darwin.read(fd, &bytes, bytes.count)
    if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
    if n <= 0 { finish(n == 0 ? nil : StreamError.failed("read errno \(errno)")); break }
    onData?(Data(bytes.prefix(n)))
   }
  }
 }
 public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
  lock.lock(); guard !closed else { lock.unlock(); completion(StreamError.closed); return }; group.enter(); queued += data.count; lock.unlock()
  writeQueue.async { [self] in
   defer { group.leave() }
   do { try USBMux.writeAll(fd, data); lock.lock(); queued -= data.count; lock.unlock(); completion(nil) }
   catch { lock.lock(); queued -= data.count; lock.unlock(); completion(error); finish(StreamError.failed("write \(error)")) }
  }
 }
 public func close() { finish(nil) }
 private func finish(_ error: Error?) {
  lock.lock(); guard !closed else { lock.unlock(); return }; closed = true; Darwin.shutdown(fd, SHUT_RDWR); let callback = closeHandler; closeHandler = nil; dataHandler = nil; lock.unlock()
  group.notify(queue: writeQueue) { [fd] in Darwin.close(fd) }; callback?(error)
 }
 deinit { lock.lock(); let open = !closed; lock.unlock(); if open { Darwin.close(fd) } }
}

/// Mac side of the USB transport: find the attached iPad and open A and B.
public enum USBDialer {
 public typealias Connection = (device: USBMux.Device, control: FDStream, video: FDStream)
 public enum Stage: String { case enumeration, noUSB, controlConnect, videoConnect, connected }
 /// The deepest completed/failed dial stage. Reason codes contain only bounded numeric system
 /// codes, never device serials or arbitrary error descriptions. A connected tunnel has not yet
 /// completed the product HELLO/authentication handshake.
 public struct DialResult {
  public let stage: Stage, reasonCode: String
  /// nil when enumeration failed; zero only when the successful list contained no USB devices.
  public let deviceCount: Int?
  public let connection: Connection?
 }
 /// Opens two streams to the iPad loopback port; nil when no device answers. Existing callers can
 /// keep this API; coordinators use dialResult() to explain USB fallback without guessing why.
 public static func dial(port: UInt16 = ProductIdentity.usbLoopbackPort) -> Connection? {
  dialResult(port: port).connection
 }
 public static func dialResult(port: UInt16 = ProductIdentity.usbLoopbackPort) -> DialResult {
  dialResult(port: port, listDevices: USBMux.devices, connect: USBMux.connect, close: { Darwin.close($0) })
 }
 /// Inject only the existing usbmux operations, so error classification and descriptor ownership
 /// are tested without probing real devices or replacing the product's transport mechanism.
 static func dialResult(port: UInt16, listDevices: () throws -> [USBMux.Device],
                        connect: (USBMux.Device, UInt16) throws -> Int32, close: (Int32) -> Void) -> DialResult {
  let devices: [USBMux.Device]
  do { devices = try listDevices() }
  catch { return DialResult(stage: .enumeration, reasonCode: reasonCode(error), deviceCount: nil, connection: nil) }
  guard !devices.isEmpty else { return DialResult(stage: .noUSB, reasonCode: "noUSB", deviceCount: 0, connection: nil) }
  var failure: DialResult?
  for device in devices {
   let control: Int32
   do { control = try connect(device, port) }
   catch {
    // A failure on a later device must not hide that another device accepted A and refused B.
    if failure?.stage != .videoConnect { failure = DialResult(stage: .controlConnect, reasonCode: reasonCode(error), deviceCount: devices.count, connection: nil) }
    continue
   }
   let video: Int32
   do { video = try connect(device, port) }
   catch {
    close(control)
    failure = DialResult(stage: .videoConnect, reasonCode: reasonCode(error), deviceCount: devices.count, connection: nil)
    continue
   }
   return DialResult(stage: .connected, reasonCode: "connected", deviceCount: devices.count, connection: (device, FDStream(fd: control), FDStream(fd: video)))
  }
  // Nonempty enumeration always attempts at least one A connection.
  return failure ?? DialResult(stage: .controlConnect, reasonCode: "unexpectedError", deviceCount: devices.count, connection: nil)
 }
 private static func reasonCode(_ error: Error) -> String {
  switch error {
  case USBMuxError.socket(let code): return "socket_\(code)"
  case USBMuxError.refused(let code): return "refused_\(code)"
  case USBMuxError.protocolError: return "protocolError"
  default: return "unexpectedError"
  }
 }
 /// Re-open only B for a video rebuild (fault row 7b).
 public static func redialVideo(device: USBMux.Device, port: UInt16 = ProductIdentity.usbLoopbackPort) -> FDStream? {
  (try? USBMux.connect(device: device, port: port)).map { FDStream(fd: $0) }
 }
}
#endif
