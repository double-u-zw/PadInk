import XCTest
@testable import PadInkCore

final class SessionDiagnosticsTests: XCTestCase {
 func testClockOffsetAndUncertaintyAreDiagnosticOnly() throws {
  let precise = try XCTUnwrap(ClockEstimate(sent: 1_000_000_000, peerReceived: 1_010_000_000, peerSent: 1_012_000_000, received: 1_004_000_000))
  XCTAssertEqual(precise.offsetMilliseconds, 9); XCTAssertEqual(precise.uncertaintyMilliseconds, 1); XCTAssertTrue(precise.reliable)
  let slow = try XCTUnwrap(ClockEstimate(sent: 0, peerReceived: 80_000_000, peerSent: 80_000_000, received: 160_000_000))
  XCTAssertFalse(slow.reliable)
  var gesture = GestureFreshness(gestureID: 1, began: ReceiveStamp(localTime: 0))
  XCTAssertEqual(gesture.verdict(for: ReceiveStamp(localTime: 0), now: 1, policy: .initial), .inject)
  XCTAssertNil(ClockEstimate(sent: 9, peerReceived: 1, peerSent: 0, received: 10))
  XCTAssertNil(ClockEstimate(sent: 9, peerReceived: 1, peerSent: 50, received: 10))
 }
 func testFaultJournalSurvivesVideoTurnoverAndIsBounded() throws {
  let d = Diagnostics(capacity: 4)
  d.fault(row: "7", reason: "controlFailed", generation: 1, now: 1)
  for n in 0..<100 { d.mark("video.presented", time: UInt64(n)) }
  XCTAssertEqual(d.report().traces.count, 4); XCTAssertEqual(d.report().faults?.first?.reason, "controlFailed")
  for n in 0..<300 { d.fault(row: "6", reason: "staleSample", generation: UInt32(n)) }
  XCTAssertEqual(d.report().faults?.count, 256)
  d.fault(row: "7", reason: "/Users/person/private-document", generation: 1)
  XCTAssertFalse(try String(decoding: JSONEncoder().encode(d.report()), as: UTF8.self).contains("private-document"))
 }
 func testUSBDiscoveryAndListenerDiagnosticsDoNotClaimActiveUSB() throws {
  var state = SessionDiagnostics(); state.transport = "wifi"; state.connection = "active"
  state.usbDialStage = "controlConnect"; state.usbDialError = "refused_3"
  state.usbDeviceCount = 1; state.usbDialAttempts = 4
  state.usbListenerState = "retrying"; state.usbListenerError = "posix_48"
  state.usbAttachmentError = "controlFailed"
  let decoded = try JSONDecoder().decode(SessionDiagnostics.self, from: JSONEncoder().encode(state))
  XCTAssertEqual(decoded.transport, "wifi"); XCTAssertEqual(decoded.connection, "active")
  XCTAssertEqual(decoded.usbDeviceCount, 1); XCTAssertEqual(decoded.usbDialError, "refused_3")
  XCTAssertEqual(decoded.usbListenerState, "retrying"); XCTAssertEqual(decoded.usbListenerError, "posix_48")
  XCTAssertEqual(decoded.usbAttachmentError, "controlFailed")
  var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
  for key in old.keys.filter({ $0.hasPrefix("usb") }) { old.removeValue(forKey: key) }
  let previous = try JSONDecoder().decode(SessionDiagnostics.self, from: JSONSerialization.data(withJSONObject: old))
  XCTAssertEqual(previous.transport, "wifi"); XCTAssertNil(previous.usbDialStage)
  XCTAssertNil(previous.usbListenerState); XCTAssertNil(previous.usbDeviceCount)
 }

 func testMetricDistributionsUseLocalSamplesAndReportRoundTrips() throws {
  let d = Diagnostics(); d.mark("input.receiveToInject", value: 50); d.mark("video.encoded", value: 2)
  var s = SessionDiagnostics(); s.transport = "usb"; s.gesture = 7; d.updateSession(s)
  let report = try JSONDecoder().decode(DiagnosticReport.self, from: JSONEncoder().encode(d.report()))
  XCTAssertEqual(report.session?.gesture, 7); XCTAssertEqual(report.metrics?.receiveToInjectMilliseconds?.max, 50)
  XCTAssertEqual(report.metrics?.encodeMilliseconds?.max, 2)
 }
 func testAbsentMeasurementsAreNotZeroLatency() throws {
  let empty = Diagnostics().report()
  XCTAssertEqual(empty.formatVersion, 3)
  XCTAssertNil(empty.metrics?.captureToSendMilliseconds)
  XCTAssertNil(empty.metrics?.decodeMilliseconds)
  XCTAssertNil(empty.metrics?.receiveToPresentMilliseconds)
  XCTAssertNil(empty.metrics?.captureFPS)
  let d = Diagnostics(); d.mark("input.captureToSend", value: 0)
  let measured = try JSONDecoder().decode(DiagnosticReport.self, from: JSONEncoder().encode(d.report()))
  XCTAssertEqual(measured.metrics?.captureToSendMilliseconds?.sampleCount, 1)
  XCTAssertEqual(measured.metrics?.captureToSendMilliseconds?.max, 0)
 }
 func testWindowTargetChangeCancelsOnceAndLateNotificationCannotCancelNewStroke() {
  var guarder = InputTargetGuard(); guarder.began(1, revision: 3)
  XCTAssertEqual(guarder.changed(to: 4), 1); XCTAssertNil(guarder.changed(to: 4))
  guarder.began(2, revision: 4); XCTAssertNil(guarder.changed(to: 4))
  XCTAssertEqual(guarder.changed(to: 5), 2); guarder.ended(); XCTAssertNil(guarder.changed(to: 6))
 }
 func testAuthenticationFailureAndForgetPauseReconnection() {
  for end in [AttachmentEnd.peerError(.authenticationFailed), .closedLocally(.forgetDevice), .peerGoodbye(.forgetDevice)] {
   var s = LogicalSession(resumeToken: Data(count: 32)); let g = s.beginAttachment()!
   _ = s.attachmentEnded(generation: g, end); XCTAssertEqual(s.state, .paused); XCTAssertNil(s.beginAttachment())
   s.userResume(); XCTAssertNotNil(s.beginAttachment())
  }
 }
}
