#if os(macOS)
import XCTest
@testable import PadInkMacKit
import PadInkCore

final class MacPresentationTests: XCTestCase {
 private func model() -> MacModel {
  let model = MacModel()
  model.screenRecordingGranted = true; model.accessibilityGranted = true
  return model
 }

 func testHandshakeDoesNotClaimTheIPadIsShowingTheScreen() {
  let model = model(); model.connected = true; model.phase = .waitingForVideo
  XCTAssertNotEqual(model.presentationTitle, ConnectionPhase.active.title)
  XCTAssertTrue(model.presentationDetail.contains("等待画面"))
  model.phase = .active
  XCTAssertEqual(model.presentationTitle, ConnectionPhase.active.title)
  XCTAssertTrue(model.presentationDetail.contains("正在显示"))
 }

 func testDeviceRemovalAndTimeoutKeepRequiredRecoveryActionsVisible() {
  let model = model(); model.phase = .paused; model.paused = true
  model.status = "已忘记设备：在 iPad 允许重新配对，再点“重新连接”"
  XCTAssertTrue(model.presentationDetail.contains("允许重新配对"))
  model.phase = .recovering; model.paused = false
  model.status = ConnectionPresentation.ended(.handshakeTimeout, peer: "iPad").message
  XCTAssertTrue(model.presentationDetail.contains("信任"))
  model.phase = .waiting; model.status = "等待 iPad 返回：请保持 PadInk 在前台"
  XCTAssertTrue(model.presentationDetail.contains("返回"))
 }

 func testPermissionsAndPairingTakePriorityWithoutChangingConnectionFacts() {
  XCTAssertFalse(MacModel().canPause, "First launch should focus on authorization")
  let model = model(); model.phase = .connecting
  model.pairing = PairingRequest(deviceID: Data([1]), name: "iPad")
  XCTAssertEqual(model.presentationTitle, "等待确认配对")
  model.screenRecordingGranted = false
  XCTAssertEqual(model.presentationTitle, "完成 Mac 授权")
  XCTAssertTrue(model.canPause, "A pending pairing can still be stopped if permissions are missing")
  XCTAssertEqual(model.phase, .connecting)
  XCTAssertNotNil(model.pairing)
  XCTAssertFalse(model.connected)
 }

 func testRoutineInputReleaseAndSuccessfulZoomDoNotBecomeWarnings() {
  let model = model()
  model.lastInputNote = "前台应用切换，已安全结束当前笔画"
  model.zoomNote = "已发送连续应用缩放"
  XCTAssertNil(model.actionableInputNote)
  XCTAssertNil(model.actionableZoomNote)
  model.lastInputNote = "输入超时，已安全结束当前操作"
  model.zoomNote = "当前应用无法缩放"
  XCTAssertNotNil(model.actionableInputNote)
  XCTAssertNotNil(model.actionableZoomNote)
 }

 func testAttentionShowsEachRequiredActionOnce() {
  let model = model(); model.phase = .needsAttention
  model.needsUpdate = "请同时更新 Mac 和 iPad"
  XCTAssertEqual(model.presentationDetail, model.needsUpdate)
  XCTAssertNil(model.actionableUpdateNote)
  model.videoNote = "屏幕录制无法启动，请检查系统权限"
  XCTAssertEqual(model.presentationDetail, model.videoNote)
  XCTAssertNil(model.actionableVideoNote)
  XCTAssertEqual(model.actionableUpdateNote, model.needsUpdate, "A separate required update remains visible")
 }
}
#endif
