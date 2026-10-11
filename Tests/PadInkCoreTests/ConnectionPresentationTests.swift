import XCTest
@testable import PadInkCore

final class ConnectionPresentationTests: XCTestCase {
 func testPreparationAndRecoveryNeverPresentAsReady() {
  for phase in [ConnectionPhase.connecting, .waitingForVideo, .recovering] {
   XCTAssertTrue(phase.isBusy)
   XCTAssertNotEqual(phase.title, ConnectionPhase.active.title)
   XCTAssertNotEqual(phase.symbolName, ConnectionPhase.active.symbolName)
  }
  for phase in [ConnectionPhase.waiting, .paused, .needsAttention, .active] {
   XCTAssertFalse(phase.isBusy, "Actionable or idle states must not imply automatic progress")
  }
  XCTAssertNotEqual(ConnectionPhase.paused.title, ConnectionPhase.recovering.title)
  XCTAssertNotEqual(ConnectionPhase.needsAttention.title, ConnectionPhase.recovering.title)
 }
 func testGeometryPreparationDoesNotClaimThatVideoHasPresented() {
  var geometry = PresentedGeometry(generation: 1, ready: false, orientation: 4, videoWidth: 2360, videoHeight: 1640)
  XCTAssertFalse(ConnectionPresentation.confirmsVideo(Frame(type: .presentedGeometry, generation: 1, sequence: 1, timestamp: 1, payload: geometry.encoded())))
  geometry.ready = true
  XCTAssertTrue(ConnectionPresentation.confirmsVideo(Frame(type: .presentedGeometry, generation: 1, sequence: 1, timestamp: 1, payload: geometry.encoded())))
  XCTAssertFalse(ConnectionPresentation.confirmsVideo(Frame(type: .presentedGeometry, generation: 1, sequence: 1, timestamp: 1, payload: Data([0]))))
  XCTAssertFalse(ConnectionPresentation.confirmsVideo(Frame(type: .heartbeat, generation: 1, sequence: 1, timestamp: 1, payload: geometry.encoded())))
 }

 func testPairingAndVersionErrorsGiveAnActionInsteadOfClaimingAutomaticRecovery() {
  let pairing = ConnectionPresentation.ended(.peerError(.authenticationFailed), peer: "Mac")
  XCTAssertEqual(pairing.phase, .needsAttention)
  XCTAssertTrue(pairing.message.contains("允许重新配对"))
  XCTAssertTrue(pairing.message.contains("重新连接"))
  let version = ConnectionPresentation.ended(.peerError(.versionMismatch), peer: "iPad")
  XCTAssertEqual(version.phase, .needsAttention)
  XCTAssertTrue(version.message.contains("Mac 和 iPad 两端"))
 }
 func testPauseAndBackgroundRemainDistinctFromLinkFailure() {
  let paused = ConnectionPresentation.ended(.peerGoodbye(.userDisconnect), peer: "Mac")
  XCTAssertEqual(paused.phase, .paused)
  XCTAssertTrue(paused.message.contains("Mac"))
  let background = ConnectionPresentation.ended(.peerGoodbye(.appBackground), peer: "Mac")
  XCTAssertEqual(background.phase, .waiting)
  XCTAssertTrue(background.message.contains("前台") || background.message.contains("返回"))
  let dead = ConnectionPresentation.ended(.dead(.controlSilent), peer: "Mac")
  XCTAssertEqual(dead.phase, .recovering)
  XCTAssertTrue(dead.message.contains("自动重连"))
  XCTAssertTrue(dead.message.contains("数据线"))
 }
 func testTimeoutAndProtocolErrorHaveDifferentRecoveryInstructions() {
  let timeout = ConnectionPresentation.ended(.handshakeTimeout, peer: "Mac")
  let protocolError = ConnectionPresentation.ended(.protocolViolation("private underlying failure"), peer: "Mac")
  XCTAssertTrue(timeout.message.contains("信任"))
  XCTAssertTrue(protocolError.message.contains("诊断"))
  XCTAssertFalse(protocolError.message.contains("private underlying failure"))
 }
 func testTransportNoticeRequiresConfirmedDifferentTransportForSamePeer() {
  var presentation = TransportPresentation()
  let peer = Data([1]), another = Data([2])
  XCTAssertNil(presentation.confirmed(.wifi, peer: peer))
  XCTAssertNil(presentation.confirmed(.wifi, peer: peer))
  XCTAssertEqual(presentation.confirmed(.usb, peer: peer), "已从 Wi-Fi 切换到 USB")
  XCTAssertNil(presentation.confirmed(.usb, peer: peer))
  XCTAssertEqual(presentation.confirmed(.wifi, peer: peer), "已从 USB 恢复 Wi-Fi")
  XCTAssertNil(presentation.confirmed(.usb, peer: another), "a different device is not an automatic switch")
 }
}
