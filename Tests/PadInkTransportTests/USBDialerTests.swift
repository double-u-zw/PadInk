#if os(macOS)
import XCTest
import Darwin
import PadInkCore
@testable import PadInkTransport

final class USBDialerTests: XCTestCase {
 private let first = USBMux.Device(id: 1, serial: "private-device-one")
 private let second = USBMux.Device(id: 2, serial: "private-device-two")
 private enum PrivateError: Error { case deviceSerial(String) }

 func testNoUSBIsSuccessfulEmptyEnumerationNotAnEnumerationFailure() {
  var attempts = 0, closed = [Int32]()
  let result = USBDialer.dialResult(port: 42371, listDevices: { [] }, connect: { _, _ in attempts += 1; return -1 }, close: { closed.append($0) })
  XCTAssertEqual(result.stage, .noUSB); XCTAssertEqual(result.reasonCode, "noUSB"); XCTAssertEqual(result.deviceCount, 0)
  XCTAssertNil(result.connection); XCTAssertEqual(attempts, 0); XCTAssertTrue(closed.isEmpty)
 }

 func testEnumerationErrorsRemainDistinctAndDoNotAttemptConnect() {
  let errors: [(Error, String)] = [(USBMuxError.socket(EACCES), "socket_13"), (USBMuxError.protocolError, "protocolError"), (PrivateError.deviceSerial(first.serial), "unexpectedError")]
  for (error, reason) in errors {
   var attempts = 0, closed = [Int32]()
   let result = USBDialer.dialResult(port: 42371, listDevices: { throw error }, connect: { _, _ in attempts += 1; return -1 }, close: { closed.append($0) })
   XCTAssertEqual(result.stage, .enumeration); XCTAssertEqual(result.reasonCode, reason); XCTAssertNil(result.deviceCount)
   XCTAssertFalse(result.reasonCode.contains(first.serial)); XCTAssertNil(result.connection); XCTAssertEqual(attempts, 0); XCTAssertTrue(closed.isEmpty)
  }
 }

 func testRecognizedUSBWithControlPortRefusedReportsRawStableCode() {
  var ports = [UInt16](), closed = [Int32]()
  let result = USBDialer.dialResult(port: 42371, listDevices: { [self.first] }, connect: { device, port in
   XCTAssertEqual(device, self.first); ports.append(port); throw USBMuxError.refused(3)
  }, close: { closed.append($0) })
  XCTAssertEqual(result.stage, .controlConnect); XCTAssertEqual(result.reasonCode, "refused_3"); XCTAssertEqual(result.deviceCount, 1)
  XCTAssertNil(result.connection); XCTAssertEqual(ports, [42371]); XCTAssertTrue(closed.isEmpty)
 }

 func testAllControlErrorKindsAreSanitized() {
  let errors: [(Error, String)] = [(USBMuxError.socket(ETIMEDOUT), "socket_60"), (USBMuxError.protocolError, "protocolError"), (PrivateError.deviceSerial(first.serial), "unexpectedError")]
  for (error, reason) in errors {
   let result = USBDialer.dialResult(port: 42371, listDevices: { [self.first] }, connect: { _, _ in throw error }, close: { _ in XCTFail("No descriptor was acquired") })
   XCTAssertEqual(result.stage, .controlConnect); XCTAssertEqual(result.reasonCode, reason); XCTAssertEqual(result.deviceCount, 1)
   XCTAssertFalse(result.reasonCode.contains(first.serial)); XCTAssertNil(result.connection)
  }
 }

 func testVideoConnectFailureClosesAcquiredControlExactlyOnce() throws {
  let pair = try socketPair(); defer { Darwin.close(pair.1) }
  var attempts = 0, closed = [Int32]()
  let result = USBDialer.dialResult(port: 42371, listDevices: { [self.first] }, connect: { _, _ in
   attempts += 1; if attempts == 1 { return pair.0 }; throw USBMuxError.refused(3)
  }, close: { closed.append($0); Darwin.close($0) })
  XCTAssertEqual(result.stage, .videoConnect); XCTAssertEqual(result.reasonCode, "refused_3"); XCTAssertEqual(result.deviceCount, 1)
  XCTAssertNil(result.connection); XCTAssertEqual(attempts, 2); XCTAssertEqual(closed, [pair.0])
  errno = 0; XCTAssertEqual(fcntl(pair.0, F_GETFD), -1); XCTAssertEqual(errno, EBADF)
 }

 func testVideoErrorKindsRetainStageAndAlwaysCloseControl() throws {
  let errors: [(Error, String)] = [(USBMuxError.socket(ECONNRESET), "socket_54"), (USBMuxError.protocolError, "protocolError"), (PrivateError.deviceSerial(first.serial), "unexpectedError")]
  for (error, reason) in errors {
   let pair = try socketPair(); defer { Darwin.close(pair.1) }
   var attempts = 0, closed = [Int32]()
   let result = USBDialer.dialResult(port: 42371, listDevices: { [self.first] }, connect: { _, _ in
    attempts += 1; if attempts == 1 { return pair.0 }; throw error
   }, close: { closed.append($0); Darwin.close($0) })
   XCTAssertEqual(result.stage, .videoConnect); XCTAssertEqual(result.reasonCode, reason)
   XCTAssertFalse(result.reasonCode.contains(first.serial)); XCTAssertNil(result.connection); XCTAssertEqual(closed, [pair.0])
  }
 }

 func testLaterControlRefusalDoesNotHideEarlierVideoFailure() throws {
  let pair = try socketPair(); defer { Darwin.close(pair.1) }
  var attempts = [Int](), closed = [Int32]()
  let result = USBDialer.dialResult(port: 42371, listDevices: { [self.first, self.second] }, connect: { device, _ in
   attempts.append(device.id)
   if attempts.count == 1 { return pair.0 }
   throw USBMuxError.refused(device.id == self.first.id ? 3 : 2)
  }, close: { closed.append($0); Darwin.close($0) })
  XCTAssertEqual(result.stage, .videoConnect); XCTAssertEqual(result.reasonCode, "refused_3"); XCTAssertEqual(result.deviceCount, 2)
  XCTAssertNil(result.connection); XCTAssertEqual(attempts, [1, 1, 2]); XCTAssertEqual(closed, [pair.0])
 }

 func testFailedDeviceCleanupDoesNotPreventNextDeviceConnecting() throws {
  let rejected = try socketPair(), control = try socketPair(), video = try socketPair()
  defer { Darwin.close(rejected.1); Darwin.close(control.1); Darwin.close(video.1) }
  var attempts = [Int](), closed = [Int32]()
  let result = USBDialer.dialResult(port: 42371, listDevices: { [self.first, self.second] }, connect: { device, _ in
   attempts.append(device.id)
   switch attempts.count {
   case 1: return rejected.0
   case 2: throw USBMuxError.refused(3)
   case 3: return control.0
   default: return video.0
   }
  }, close: { closed.append($0); Darwin.close($0) })
  XCTAssertEqual(result.stage, .connected); XCTAssertEqual(result.reasonCode, "connected"); XCTAssertEqual(result.deviceCount, 2)
  let connection = try XCTUnwrap(result.connection); XCTAssertEqual(connection.device, second)
  XCTAssertEqual(attempts, [1, 1, 2, 2]); XCTAssertEqual(closed, [rejected.0])
  // Success transfers both live descriptors to FDStream; failure cleanup must not close them.
  XCTAssertNotEqual(fcntl(control.0, F_GETFD), -1); XCTAssertNotEqual(fcntl(video.0, F_GETFD), -1)
  connection.control.close(); connection.video.close()
 }

 func testSuccessOpensExactlyTwoStreamsOnRequestedPortAndTransfersOwnership() throws {
  let control = try socketPair(), video = try socketPair(); defer { Darwin.close(control.1); Darwin.close(video.1) }
  var attempts = 0, ports = [UInt16](), closed = [Int32]()
  let result = USBDialer.dialResult(port: 43210, listDevices: { [self.first] }, connect: { device, port in
   XCTAssertEqual(device, self.first); attempts += 1; ports.append(port); return attempts == 1 ? control.0 : video.0
  }, close: { closed.append($0); Darwin.close($0) })
  XCTAssertEqual(result.stage, .connected); XCTAssertEqual(result.reasonCode, "connected"); XCTAssertEqual(result.deviceCount, 1)
  let connection = try XCTUnwrap(result.connection); XCTAssertEqual(connection.device, first)
  XCTAssertEqual(attempts, 2); XCTAssertEqual(ports, [43210, 43210]); XCTAssertTrue(closed.isEmpty)
  let sent = expectation(description: "control bytes")
  connection.control.send(Data([1, 2, 3])) { error in XCTAssertNil(error); sent.fulfill() }
  XCTAssertEqual(try USBMux.readExact(control.1, 3), Data([1, 2, 3])); wait(for: [sent], timeout: 2)
  connection.control.close(); connection.video.close()
 }

 private func socketPair() throws -> (Int32, Int32) {
  var fds: [Int32] = [-1, -1]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw USBMuxError.socket(errno) }
  return (fds[0], fds[1])
 }
}
#endif
