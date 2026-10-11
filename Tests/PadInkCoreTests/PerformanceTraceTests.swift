import XCTest
@testable import PadInkCore

final class PerformanceTraceTests: XCTestCase {
 func testDisabledRecorderDoesNotEvaluateEvent() {
  let recorder = PerformanceRecorder(enabled: false)
  var evaluated = false
  func event() -> PerformanceEvent { evaluated = true; return PerformanceEvent("unexpected") }
  recorder.record(event())
  XCTAssertFalse(evaluated); XCTAssertNil(recorder.report())
 }
 func testBoundedRingAndReleaseCannotEnable() throws {
  let recorder = PerformanceRecorder(enabled: true, capacity: 2)
  for i in 0..<4 { recorder.record(PerformanceEvent("input.postCall", time: UInt64(i))) }
  #if DEBUG
  let result = try XCTUnwrap(recorder.report())
  XCTAssertEqual(result.events.map(\.time), [2, 3]); XCTAssertEqual(result.overwritten, 2)
  #else
  XCTAssertFalse(recorder.enabled); XCTAssertNil(recorder.report())
  #endif
 }
 func testPerformanceExportOptInIsSeparateFromCoordinatesAndRecovery() throws {
  let recorder = PerformanceRecorder(enabled: true)
  let diagnostic = Diagnostics(developerDetailed: false, performance: recorder)
  let sample = PencilSample(stroke: 1, sequence: 1, timestamp: 123, x: 0.7, y: 0.2, pressure: 0.8, altitude: 1, azimuth: 1, phase: .begin)
  diagnostic.mark("input.raw", session: 7, sample: sample)
  XCTAssertNil(diagnostic.report().supportSafe().performance)
  XCTAssertNil(diagnostic.report(includePerformance: false).performance)
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let data = try Data(contentsOf: diagnostic.export(to: dir))
  let report = try JSONDecoder().decode(DiagnosticReport.self, from: data)
  #if DEBUG
  XCTAssertEqual(report.performance?.events.first?.start, 123)
  XCTAssertEqual(report.performance?.events.first?.generation, 7)
  #else
  XCTAssertNil(report.performance)
  #endif
  XCTAssertNil(report.traces.first?.x); XCTAssertNil(report.traces.first?.pressure)
  let disabled = Diagnostics(performance: PerformanceRecorder(enabled: false))
  let stripped = try JSONDecoder().decode(DiagnosticReport.self, from: Data(contentsOf: disabled.write(report, to: dir)))
  XCTAssertNil(stripped.performance)
 }
 func testConcurrentProducersAndSnapshotsHaveAccountedLoss() {
  let recorder = PerformanceRecorder(enabled: true, capacity: 100)
  DispatchQueue.concurrentPerform(iterations: 2000) { i in
   recorder.record(PerformanceEvent("load", time: UInt64(i)))
   if i % 100 == 0 { _ = recorder.report() }
  }
  #if DEBUG
  let report = recorder.report()!
  XCTAssertEqual(UInt64(report.events.count) + report.overwritten + report.contentionDrops, 2000)
  #endif
 }
}
