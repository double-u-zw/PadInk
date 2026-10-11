import XCTest
@testable import PadInkCore

final class DiagnosticReleaseTests: XCTestCase {
 private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("padink-recovery-test-\(UUID())", isDirectory: true) }
 private func markPrivateInput(_ diagnostics: Diagnostics) {
  let sample = PencilSample(stroke: 9, sequence: 4, timestamp: 1234, x: 0.42, y: 0.72, pressure: 0.8, altitude: 1, azimuth: 2, phase: .begin)
  diagnostics.mark("input.callbackRaw", time: 10_000, sample: sample, state: "/Users/person/private-document", value: 0.8,
   eventTime: 1234, screenX: 510, screenY: 220, viewX: 77, viewY: 88)
 }
 func testDefaultMemoryAndExportOmitTrajectoryPressureAndArbitraryState() throws {
  let diagnostics = Diagnostics(developerDetailed: false); markPrivateInput(diagnostics)
  diagnostics.mark("input.receiveToInject", time: 10_500, value: 2)
  diagnostics.fault(row: "7", reason: "controlFailed", generation: 1, now: 10_100)
  let memory = try XCTUnwrap(diagnostics.snapshot().first)
  XCTAssertNil(memory.x); XCTAssertNil(memory.pressure); XCTAssertNil(memory.screenX); XCTAssertNil(memory.state); XCTAssertNil(memory.value)
  let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
  let exported = try Data(contentsOf: diagnostics.export(to: root))
  let text = String(decoding: exported, as: UTF8.self)
  for key in ["\"x\"", "\"y\"", "\"pressure\"", "\"screenX\"", "\"viewX\"", "\"sourceTime\"", "\"eventTime\"", "private-document"] { XCTAssertFalse(text.contains(key), key) }
  let report = try JSONDecoder().decode(DiagnosticReport.self, from: exported)
  XCTAssertEqual(report.detail, "support"); XCTAssertEqual(report.traces.first?.time, 0)
  XCTAssertEqual(report.faults?.first?.time, 100); XCTAssertEqual(report.faults?.first?.reason, "controlFailed")
  XCTAssertEqual(report.metrics?.receiveToInjectMilliseconds?.max, 2)
 }
 func testSupportExportRemovesCrossDeviceClockAndEnforcesPolicyOnProvidedReport() throws {
  let diagnostics = Diagnostics(developerDetailed: false); var session = SessionDiagnostics()
  session.clock = ClockEstimate(sent: 0, peerReceived: 20, peerSent: 20, received: 40); diagnostics.updateSession(session)
  var report = diagnostics.report()
  var trace = Trace(stage: "touch.inject", session: 1, item: 1, sequence: 1, time: 5000)
  trace.x = 0.5; trace.viewX = 100; trace.pressure = 0.7; trace.value = 88; trace.state = "documentName"
  report.traces = [trace]
  let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
  let decoded = try JSONDecoder().decode(DiagnosticReport.self, from: Data(contentsOf: diagnostics.write(report, to: root)))
  XCTAssertNil(decoded.session?.clock); XCTAssertNil(decoded.traces.first?.pressure)
  XCTAssertNil(decoded.traces.first?.value); XCTAssertNil(decoded.traces.first?.state)
 }
 func testSupportRetainsOnlyFixedTouchPhaseVocabularyWithoutMovementValues() {
  let diagnostics = Diagnostics(developerDetailed: false)
  diagnostics.mark("touch.inject", state: "magnify:changed", value: 0.123, viewX: 100)
  diagnostics.mark("touch.inject", state: "documentName", value: 0.42)
  let records = diagnostics.snapshot()
  XCTAssertEqual(records[0].state, "magnify:changed"); XCTAssertNil(records[0].value); XCTAssertNil(records[0].viewX)
  XCTAssertNil(records[1].state); XCTAssertNil(records[1].value)
 }
 func testDetailedCoordinatesRequireExplicitDebugOnlyOptIn() throws {
  let diagnostics = Diagnostics(developerDetailed: true); markPrivateInput(diagnostics)
  #if DEBUG
  XCTAssertEqual(diagnostics.snapshot().first?.x, 0.42); XCTAssertEqual(diagnostics.report().detail, "developer-local-detailed")
  #else
  XCTAssertNil(diagnostics.snapshot().first?.x); XCTAssertEqual(diagnostics.report().detail, "support")
  #endif
 }
 func testUnfinishedRunRetainsBoundedSupportCheckpointAndNormalRunDoesNotInventCrash() throws {
  let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
  let diagnostics = Diagnostics(developerDetailed: false)
  var session = SessionDiagnostics(); session.applyBuild(BuildIdentity(version: "0.3.0", source: "build", build: "1", channel: "rc", sourceRevision: String(repeating: "a", count: 40), sourceDigest: String(repeating: "b", count: 64)))
  diagnostics.updateSession(session)
  for index in 0..<300 { diagnostics.mark("video.presented", time: UInt64(index)); diagnostics.fault(row: "7", reason: "controlFailed", generation: 1, now: UInt64(index)) }
  let first = DiagnosticRecoveryStore(directory: root)
  XCTAssertNil(try first.begin(report: diagnostics.report()))
  try first.checkpoint(report: diagnostics.report())
  let second = DiagnosticRecoveryStore(directory: root)
  let recovered = try XCTUnwrap(second.begin(report: diagnostics.report()))
  XCTAssertEqual(recovered.traces.count, 128); XCTAssertEqual(recovered.faults.count, 128)
  XCTAssertEqual(recovered.session?.buildNumber, "1"); XCTAssertEqual(recovered.session?.sourceDigest?.count, 64)
  let size = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("last-session.json").path)[.size] as? NSNumber
  XCTAssertLessThan(try XCTUnwrap(size).intValue, DiagnosticRecoveryStore.maximumFileBytes)
  try second.checkpoint(report: diagnostics.report(), endedNormally: true)
  let third = DiagnosticRecoveryStore(directory: root)
  XCTAssertNil(try third.begin(report: diagnostics.report()), "A normal last run must not be announced as unfinished")
  XCTAssertNotNil(third.previousUnfinishedSession, "Keep the bounded earlier checkpoint available for support")
  let cleanRoot = directory(); defer { try? FileManager.default.removeItem(at: cleanRoot) }
  let clean = DiagnosticRecoveryStore(directory: cleanRoot); _ = try clean.begin(report: diagnostics.report())
  try clean.checkpoint(report: diagnostics.report(), endedNormally: true)
  XCTAssertNil(try DiagnosticRecoveryStore(directory: cleanRoot).begin(report: diagnostics.report()))
 }
 func testFinishedSessionCannotBeReopenedByQueuedCheckpoint() throws {
  let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
  let diagnostics = Diagnostics(developerDetailed: false)
  XCTAssertFalse(try diagnostics.beginSessionRecovery(in: root))
  diagnostics.finishSessionRecovery()
  diagnostics.checkpointSessionRecovery(force: true)
  // begin uses the same serial utility queue as a deterministic barrier: the queued late
  // checkpoint has executed before the persisted marker for the next run is read.
  XCTAssertFalse(try diagnostics.beginSessionRecovery(in: root))
  diagnostics.finishSessionRecovery()
 }
 func testImportedHistoricalSnapshotIsSanitizedAgain() throws {
  let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
  let diagnostics = Diagnostics(developerDetailed: false); diagnostics.mark("input.callbackRaw", time: 100)
  let store = DiagnosticRecoveryStore(directory: root); _ = try store.begin(report: diagnostics.report())
  let file = root.appendingPathComponent("last-session.json")
  var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
  var current = try XCTUnwrap(record["current"] as? [String: Any])
  var traces = try XCTUnwrap(current["traces"] as? [[String: Any]])
  traces[0]["x"] = 0.42; traces[0]["pressure"] = 0.7; traces[0]["state"] = "private-document"
  traces[0]["value"] = 0.7; traces[0]["sourceTime"] = 123456
  current["traces"] = traces; record["current"] = current
  try JSONSerialization.data(withJSONObject: record).write(to: file)
  let next = Diagnostics(developerDetailed: false); XCTAssertTrue(try next.beginSessionRecovery(in: root))
  let recovered = try XCTUnwrap(next.report().previousUnfinishedSession?.traces.first)
  XCTAssertNil(recovered.x); XCTAssertNil(recovered.pressure); XCTAssertNil(recovered.state)
  XCTAssertNil(recovered.value); XCTAssertNil(recovered.sourceTime)
 }
 func testRecoveryIgnoresCorruptOrOversizedFileAndExportCarriesPreviousRun() throws {
  let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let file = root.appendingPathComponent("last-session.json")
  try Data(repeating: 32, count: DiagnosticRecoveryStore.maximumFileBytes + 1).write(to: file)
  let first = Diagnostics(developerDetailed: false)
  XCTAssertFalse(try first.beginSessionRecovery(in: root))
  let second = Diagnostics(developerDetailed: false)
  XCTAssertTrue(try second.beginSessionRecovery(in: root)); XCTAssertNotNil(second.report().previousUnfinishedSession)
  second.finishSessionRecovery()
  try Data("not-json".utf8).write(to: file)
  XCTAssertFalse(try Diagnostics(developerDetailed: false).beginSessionRecovery(in: root))
 }
}
