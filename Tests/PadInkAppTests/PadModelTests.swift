import XCTest
import Combine
import PadInkPadKit
import PadInkCore

final class PadModelTests: XCTestCase {
 func testRepeatedPresentationsDoNotPublishUnchangedStatusAtVideoCadence() {
  let model = PadModel(); model.phase = .waitingForVideo; model.status = "已连接，等待画面"; model.videoNote = "正在接收画面"
  var notifications = 0
  let observation = model.objectWillChange.sink { notifications += 1 }
  XCTAssertTrue(model.videoPresented())
  XCTAssertEqual(model.phase, .active)
  XCTAssertEqual(notifications, 3)
  for _ in 0..<600 { XCTAssertFalse(model.videoPresented()) }
  XCTAssertEqual(notifications, 3, "video cadence must not become SwiftUI update cadence")
  withExtendedLifetime(observation) {}
 }
 func testRecoveryPublishesOnceAndGeometryAcknowledgementCanContinue() {
  let model = PadModel(); _ = model.videoPresented()
  model.phase = .recovering; model.videoNote = "画面解码正在恢复"
  var notifications = 0
  let observation = model.objectWillChange.sink { notifications += 1 }
  XCTAssertTrue(model.videoPresented()); XCTAssertNil(model.videoNote)
  XCTAssertEqual(model.phase, .active)
  XCTAssertEqual(notifications, 2)
  for _ in 0..<60 { XCTAssertFalse(model.videoPresented()) }
  XCTAssertEqual(notifications, 2)
  withExtendedLifetime(observation) {}
 }
}
