import XCTest
import AppKit
import PadInkCore
@testable import PadInkMacKit

final class InputFaultDiagnosticsTests: XCTestCase {
 func testPencilAndTouchFaultMatrixReleasesOnceWithMatchingSession() throws {
  let reasons: [CancelReason] = [.staleSample,.geometryMismatch,.targetChanged,.gestureTimeout,.transportLost,.sessionReplaced,.protocolViolation,.pencilPreempted,.settingsChanged,.appBackground]
  let expected: [String?] = ["2","4","5","6","7","7","8",nil,nil,nil]
  for (reason,row) in zip(reasons,expected) {
   let pd = Diagnostics(), td = Diagnostics(); var penEvents: [CGEventType] = [], touchEvents: [CGEventType] = []
   let pen = PencilInputPipeline(backend: PencilInjectionBackend(diagnostics: pd, postEvent: { penEvents.append($0.type) }), diagnostics: pd)
   let touch = TouchInputPipeline(backend: PointerInjectionBackend(postEvent: { touchEvents.append($0.type) }), diagnostics: td)
   let geometry = PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 1000, videoHeight: 500)
   pen.attach(generation: 42); pen.presentedGeometry(geometry); touch.attach(generation: 42); touch.setEnabled(true); touch.geometry(geometry)
   let b = try PencilBatch([PencilSample(stroke: 1, sequence: 1, timestamp: 1, x: 0.5, y: 0.5, pressure: 0.5, altitude: 1, azimuth: 0, phase: .begin, geometryGeneration: 1)])
   pen.pencil(b, stamp: .init(localTime: 0), now: 0)
   let e = TouchEvent(gestureID: (1 << 63) + 1, sequence: 1, timestamp: 1, geometryGeneration: 1, kind: .pointer, phase: .began, x: 0.5, y: 0.5)
   touch.receive(e, stamp: .init(localTime: 0), now: 0, pencilActive: false)
   pen.cancelAll(reason); touch.cancel(reason); pen.cancelAll(reason); touch.cancel(reason)
   XCTAssertNil(pen.ownership.active); XCTAssertNil(touch.ownership.active); XCTAssertFalse(pen.backend.active); XCTAssertFalse(touch.backend.pressed)
   XCTAssertEqual(penEvents.filter { $0 == .leftMouseUp }.count,1); XCTAssertEqual(touchEvents.filter { $0 == .leftMouseUp }.count,1)
   for d in [pd,td] {
    XCTAssertEqual(d.report().faults?.count,row == nil ? 0 : 1)
    XCTAssertEqual(d.report().faults?.first?.row,row)
    if row != nil { XCTAssertEqual(d.report().faults?.first?.generation,42) }
   }
  }
 }
 func testPhysicalModelIsReportedWithoutHostName() {
  XCTAssertFalse(HardwareModel.current.isEmpty); XCTAssertLessThan(HardwareModel.current.count,128)
  XCTAssertTrue(HardwareModel.current.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ",") })
 }
}
