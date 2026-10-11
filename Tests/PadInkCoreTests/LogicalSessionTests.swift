import XCTest
@testable import PadInkCore

final class LogicalSessionTests: XCTestCase {
 private func session() -> LogicalSession { LogicalSession(resumeToken: Data(repeating: 7, count: 32)) }

 func testGenerationIncrementsPerAttachmentAndTokenIsStable() {
  var s = session()
  XCTAssertEqual(s.beginAttachment(), 1); XCTAssertNil(s.beginAttachment(), "one attachment at a time")
  s.attachmentReady(generation: 1); XCTAssertEqual(s.state, .active(1))
  XCTAssertEqual(s.attachmentEnded(generation: 1, .dead(.controlSilent)), .cancelInputAndReconnect)
  XCTAssertEqual(s.state, .reconnecting); XCTAssertEqual(s.beginAttachment(), 2); XCTAssertEqual(s.resumeToken, Data(repeating: 7, count: 32))
 }

 /// Fault row 7: transport death never destroys the logical session; input is cancelled first.
 func testTransportDeathCancelsInputThenReconnects() {
  var s = session(); let g = s.beginAttachment()!; s.attachmentReady(generation: g)
  XCTAssertEqual(s.attachmentEnded(generation: g, .dead(.controlFailed)), .cancelInputAndReconnect)
  XCTAssertEqual(s.reconnects, 1)
 }

 func testFailedAttachBeforeReadyRetriesWithoutInputCancel() {
  var s = session(); let g = s.beginAttachment()!
  XCTAssertEqual(s.attachmentEnded(generation: g, .handshakeTimeout), .reconnect)
 }

 func testLateEndOfOldGenerationIsIgnored() {
  var s = session(); let g1 = s.beginAttachment()!; s.attachmentReady(generation: g1)
  _ = s.attachmentEnded(generation: g1, .dead(.controlSilent)); let g2 = s.beginAttachment()!; s.attachmentReady(generation: g2)
  XCTAssertEqual(s.attachmentEnded(generation: g1, .dead(.controlSilent)), .stayOffline)
  XCTAssertEqual(s.state, .active(g2))
 }

 func testUserDisconnectPausesUntilResume() {
  var s = session(); let g = s.beginAttachment()!; s.attachmentReady(generation: g)
  s.userDisconnect(); XCTAssertEqual(s.attachmentEnded(generation: g, .closedLocally(.userDisconnect)), .stayOffline)
  XCTAssertNil(s.beginAttachment()); s.userResume(); XCTAssertNotNil(s.beginAttachment())
 }

 func testVersionMismatchStopsReconnectStorm() {
  var s = session(); let g = s.beginAttachment()!
  XCTAssertEqual(s.attachmentEnded(generation: g, .peerError(.versionMismatch)), .stayOffline)
  XCTAssertEqual(s.state, .needsUpdate(.updateThisDevice)); XCTAssertNil(s.beginAttachment())
 }
}

/// Review of 71bdd94, P1 #4: system-initiated local closes must reconnect; only the user pauses.
final class ReconnectScenarioTests: XCTestCase {
 private let s1: UInt64 = 1_000_000_000
 private func active() -> (LogicalSession, DialGate, UInt32) {
  var s = LogicalSession(resumeToken: Data(repeating: 1, count: 32)); var gate = DialGate(); gate.permissionsGranted = true
  XCTAssertTrue(gate.shouldDial(now: 0, attached: false, session: s)); gate.attempted(now: 0); gate.finishedAttempt()
  let g = s.beginAttachment()!; s.attachmentReady(generation: g); return (s, gate, g)
 }
 func testDisplayChangeReconnectsWithANewGeneration() {
  var (s, gate, g) = active()
  XCTAssertFalse(gate.shouldDial(now: 5 * s1, attached: true, session: s))
  XCTAssertEqual(s.attachmentEnded(generation: g, .closedLocally(.settingsChanged)), .cancelInputAndReconnect)
  XCTAssertTrue(gate.shouldDial(now: 5 * s1, attached: false, session: s))
  XCTAssertEqual(s.beginAttachment(), g + 1)
 }
 func testPermissionLossWaitsAndRestoreReconnects() {
  var (s, gate, g) = active()
  gate.permissionsGranted = false
  _ = s.attachmentEnded(generation: g, .closedLocally(.settingsChanged))
  XCTAssertFalse(gate.shouldDial(now: 9 * s1, attached: false, session: s))
  gate.permissionsGranted = true
  XCTAssertTrue(gate.shouldDial(now: 9 * s1, attached: false, session: s)); XCTAssertNotNil(s.beginAttachment())
 }
 func testSleepWaitsAndWakeReconnectsImmediately() {
  var (s, gate, g) = active()
  gate.sleeping = true
  _ = s.attachmentEnded(generation: g, .closedLocally(.appBackground))
  XCTAssertFalse(gate.shouldDial(now: 60 * s1, attached: false, session: s))
  gate.attempted(now: 60 * s1); gate.finishedAttempt(); gate.woke()
  XCTAssertTrue(gate.shouldDial(now: 60 * s1, attached: false, session: s), "no interval wait after wake")
  XCTAssertNotNil(s.beginAttachment())
 }
 func testOnlyUserDisconnectPauses() {
  var (s, gate, g) = active()
  _ = s.attachmentEnded(generation: g, .closedLocally(.userDisconnect))
  XCTAssertEqual(s.state, .paused); XCTAssertFalse(gate.shouldDial(now: 9 * s1, attached: false, session: s))
  s.userResume(); XCTAssertTrue(gate.shouldDial(now: 9 * s1, attached: false, session: s))
 }
 func testDialIntervalAndSingleAttemptInFlight() {
  var s = LogicalSession(resumeToken: Data(count: 32)); var gate = DialGate(); gate.permissionsGranted = true
  gate.attempted(now: 0)
  XCTAssertFalse(gate.shouldDial(now: 2 * s1, attached: false, session: s), "attempt still running")
  gate.finishedAttempt()
  XCTAssertFalse(gate.shouldDial(now: s1 - 1, attached: false, session: s)); XCTAssertTrue(gate.shouldDial(now: s1, attached: false, session: s))
  _ = s.beginAttachment(); XCTAssertFalse(gate.shouldDial(now: 3 * s1, attached: false, session: s), "attaching")
 }
}
