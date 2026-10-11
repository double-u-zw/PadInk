#if os(macOS)
import XCTest
@testable import PadInkMacKit
import PadInkTransport

final class USBStatusTests: XCTestCase {
 func testRecognizedUSBFailureIsVisibleWhileWiFiRemainsActive() {
  XCTAssertNotNil(MacCoordinator.usbNote(stage: .controlConnect, attachmentError: nil, activeUSB: false))
  XCTAssertNotNil(MacCoordinator.usbNote(stage: .videoConnect, attachmentError: nil, activeUSB: false))
  XCTAssertNotNil(MacCoordinator.usbNote(stage: .connected, attachmentError: "controlFailed", activeUSB: false))
 }
 func testSystemMuxFailureIsNotBlamedOnIPadListener() throws {
  let refused = try XCTUnwrap(MacCoordinator.usbNote(stage: .controlConnect, reason: "refused_3", attachmentError: nil, activeUSB: false))
  XCTAssertTrue(refused.contains("iPad"))
  for reason in ["socket_13", "protocolError"] {
   let note = try XCTUnwrap(MacCoordinator.usbNote(stage: .controlConnect, reason: reason, attachmentError: nil, activeUSB: false))
   XCTAssertFalse(note.contains("iPad")); XCTAssertTrue(note.contains("诊断"))
  }
 }
 func testRawTunnelsDoNotClaimUSBReadyAndActiveUSBClearsFallbackNotice() {
  XCTAssertNil(MacCoordinator.usbNote(stage: .connected, attachmentError: nil, activeUSB: false))
  XCTAssertNil(MacCoordinator.usbNote(stage: .noUSB, attachmentError: "controlFailed", activeUSB: false))
  XCTAssertNil(MacCoordinator.usbNote(stage: .controlConnect, attachmentError: "controlFailed", activeUSB: true))
 }
}
#endif
