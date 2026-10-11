import XCTest
import CoreGraphics
@testable import PadInkCore

// Ported from Baseline v0.1.0 Tests/PadInkCoreTests/CoreTests.swift. Test names are kept so the
// Baseline evidence can be traced. Adaptations: the 48-byte PINK v3 sample encoding became
// PencilBatch (PINK/2), the u16 geometry revision became a u32 generation, VideoFrame is built
// from a payload plus the header KEYFRAME flag. Dropped tests and reasons: docs/ARCHITECTURE.md §10.

final class PencilTests: XCTestCase {
 func sample(_ seq: UInt64, _ phase: PencilPhase, stroke: UInt64 = 1, x: Float = 0.5) -> PencilSample { PencilSample(stroke: stroke, sequence: seq, timestamp: seq * 100, x: x, y: 0.25, pressure: 0.7, altitude: 0.8, azimuth: 0.3, phase: phase) }
 func testBatchPreservesActualValues() throws { let v = [sample(1, .begin), sample(2, .move), sample(3, .end, x: 0.9)]; XCTAssertEqual(try PencilBatch(PencilBatch(v).encoded()).pencilSamples, v) }
 func testDownMovesEndpointUp() throws { var state = InputSession(); let begin = sample(1, .begin), move = sample(2, .move), end = sample(3, .end, x: 0.99); XCTAssertEqual(try state.consume([begin, move, end]), [.proximityIn, .down(begin), .move(move), .up(end), .proximityOut]); XCTAssertNil(state.active) }
 func testTerminalCoalescedSamples() throws { var state = InputSession(); _ = try state.consume([sample(1, .begin)]); let v = [sample(2, .move, x: 0.7), sample(3, .move, x: 0.8), sample(4, .end, x: 0.9)]; let actions = try state.consume(v); XCTAssertEqual(actions, [.move(v[0]), .move(v[1]), .up(v[2]), .proximityOut]) }
 func testCancelSafeUp() throws { var s = InputSession(); _ = try s.consume([sample(1, .begin)]); let end = sample(2, .cancel); XCTAssertEqual(try s.consume([end]), [.up(end), .proximityOut]) }
 func testDisconnectAndIdempotentReset() throws { var s = InputSession(); let b = sample(1, .begin); _ = try s.consume([b]); XCTAssertEqual(s.reset(), [.up(b), .proximityOut]); XCTAssertTrue(s.reset().isEmpty); XCTAssertThrowsError(try s.consume([sample(2, .move)])) }
 func testDuplicateRejectedTransactionally() throws { var s = InputSession(); let b = sample(1, .begin); _ = try s.consume([b]); XCTAssertThrowsError(try s.consume([sample(2, .move), sample(2, .move)])); XCTAssertEqual(s.active, b) }
 func testMissingSampleRejected() throws { var s = InputSession(); _ = try s.consume([sample(1, .begin)]); XCTAssertThrowsError(try s.consume([sample(3, .end)])) }
 func testInterruptedStrokeCannotBeginAgain() throws { var s = InputSession(); _ = try s.consume([sample(1, .begin)]); XCTAssertThrowsError(try s.consume([sample(1, .begin, stroke: 2)])) }
 func testCompletedStrokeCannotReplay() throws { var s = InputSession(); _ = try s.consume([sample(1, .begin), sample(2, .end)]); XCTAssertThrowsError(try s.consume([sample(1, .begin)])); _ = try s.consume([sample(1, .begin, stroke: 2)]) }
 func testPressureAndTilt() throws { let s = sample(1, .begin); XCTAssertEqual(s.pressure, 0.7); XCTAssertEqual(s.tilt.0, atan2(cos(0.8) * cos(0.3), sin(0.8)) / (Double.pi / 2), accuracy: 0.000001) }
 func testRejectInvalidRealValues() throws { for value: Float in [.nan, .infinity, -1, 2] { var s = sample(1, .begin); s.pressure = value; XCTAssertThrowsError(try s.validate()) } }
 func testBatchLimitAndTruncation() throws {
  let many = (1...257).map { sample(UInt64($0), $0 == 1 ? .begin : .move) }
  XCTAssertThrowsError(try PencilBatch(many))
  let data = try PencilBatch([sample(1, .begin)]).encoded(); XCTAssertThrowsError(try PencilBatch(Data(data.dropLast())))
 }
 func testTimeCannotRegress() throws { var state = InputSession(); _ = try state.consume([sample(1, .begin)]); var s = sample(2, .move); s.timestamp = 1; XCTAssertThrowsError(try state.consume([s])) }
 /// 0.3 addition: iPad stroke IDs restart after an app relaunch; Baseline reset clears the floor.
 func testResetAllowsRestartedStrokeIDs() throws { var s = InputSession(); _ = try s.consume([sample(1, .begin, stroke: 5)]); _ = s.reset(); XCTAssertNoThrow(try s.consume([sample(1, .begin, stroke: 1)])) }
 func testBatchRejectsMixedStrokeOrGeneration() { var other = sample(2, .move); other.stroke = 2; XCTAssertThrowsError(try PencilBatch([sample(1, .begin), other])); var gen = sample(2, .move); gen.geometryGeneration = 2; XCTAssertThrowsError(try PencilBatch([sample(1, .begin), gen])) }
}

final class VideoTests: XCTestCase {
 func frame(_ id: UInt64, key: Bool = false, g: UInt32 = 1) -> VideoFrame { VideoFrame(generation: g, id: id, captureTime: 100, key: key, avcc: Data([0, 0, 0, 1, key ? 0x65 : 0x41])) }
 func testFrameHeaderAndIDR() throws { let f = frame(1, key: true); let d = try VideoFrame(payload: f.encode(), keyframe: true); XCTAssertTrue(d.key); XCTAssertEqual(d.id, 1); XCTAssertEqual(d.avcc, f.avcc) }
 func testFakeIDRRejected() { XCTAssertThrowsError(try VideoFrame(payload: frame(1).encode(), keyframe: true)) }
 func testInvalidNALLengthRejected() { var f = frame(1); f.avcc = Data([255, 255, 255, 255, 1]); XCTAssertThrowsError(try VideoFrame(payload: f.encode(), keyframe: false)) }
 func testBoundedGOPRecovery() { var q = GOPQueue(capacity: 2); XCTAssertFalse(q.push(frame(1))); XCTAssertTrue(q.push(frame(2, key: true))); XCTAssertTrue(q.push(frame(3))); XCTAssertFalse(q.push(frame(4))); XCTAssertTrue(q.frames.isEmpty); XCTAssertFalse(q.push(frame(5))); XCTAssertTrue(q.push(frame(6, key: true))); XCTAssertEqual(q.pop()?.id, 6); XCTAssertEqual(q.resets, 1) }
 func testReferenceOrder() { var g = DecodeGate(); g.configure(1); XCTAssertFalse(g.accept(frame(1))); XCTAssertTrue(g.accept(frame(2, key: true))); XCTAssertTrue(g.accept(frame(3))); XCTAssertFalse(g.accept(frame(5))); XCTAssertFalse(g.accept(frame(6))); XCTAssertTrue(g.accept(frame(7, key: true))) }
 func testDecoderResetRejectsOldGeneration() { var g = DecodeGate(); g.configure(1); XCTAssertTrue(g.accept(frame(1, key: true))); g.reset(); XCTAssertFalse(g.accept(frame(2))); g.configure(2); XCTAssertFalse(g.accept(frame(3, key: true))); XCTAssertTrue(g.accept(frame(1, key: true, g: 2))) }
 func testRawLatestWins() { let l = Latest<Int>(); l.put(1); l.put(2); XCTAssertEqual(l.take(), 2); XCTAssertNil(l.take()); XCTAssertEqual(l.overwrites, 1) }
 func testConfigRoundTrip() throws { let c = VideoConfig(generation: 1, width: 2732, height: 1536, sps: Data([1]), pps: Data([2])); XCTAssertEqual(try VideoConfig(c.encode()), c) }
 func testRasterAvoidsUpscaleAndKeepsAspect() { let r = VideoGeometry.raster(source: CGSize(width: 3024, height: 1964), drawable: CGSize(width: 2732, height: 2048)); XCTAssertEqual(r.width, 2732); XCTAssertGreaterThan(r.height, 1700); XCTAssertEqual(Int(r.height) % 2, 0) }
 func testPendingNewestRawSurvivesRecoveryReplay() { let slot = Latest<Int>(); slot.put(2); slot.putIfEmpty(1); XCTAssertEqual(slot.take(), 2); slot.putIfEmpty(3); XCTAssertEqual(slot.take(), 3) }
}

final class GeometryAndDiagnosticsTests: XCTestCase {
 func testAspectFitAndLetterbox() { let g = VideoGeometry(source: CGSize(width: 1920, height: 1080), bounds: CGRect(x: 0, y: 0, width: 1024, height: 768)); XCTAssertEqual(g.rect, CGRect(x: 0, y: 96, width: 1024, height: 576)); XCTAssertNil(g.normalized(CGPoint(x: 10, y: 10))); XCTAssertEqual(g.normalized(CGPoint(x: 512, y: 384)), CGPoint(x: 0.5, y: 0.5)) }
 func testOrientationAndClamping() { let g = VideoGeometry(source: CGSize(width: 1920, height: 1080), bounds: CGRect(x: 0, y: 0, width: 768, height: 1024)); XCTAssertEqual(g.rect.width, 768); XCTAssertEqual(g.normalized(CGPoint(x: -1, y: -1), clamp: true), .zero) }
 func testOverlayHasNoGeometryInput() { let g = VideoGeometry(source: CGSize(width: 100, height: 100), bounds: CGRect(x: 0, y: 0, width: 200, height: 100)); let before = g.rect; for _ in 0..<100 { XCTAssertEqual(g.rect, before) } }
 func testBoundedTimeline() { let d = Diagnostics(capacity: 3); for i in 0..<10 { d.mark("a", item: UInt64(i)) }; XCTAssertEqual(d.snapshot().map(\.item), [7, 8, 9]) }
 func testSlowDiagnosticReaderDoesNotBlockPencilCapture() {
  let d = Diagnostics(capacity: 32768); for i in 0..<32768 { d.mark("input.raw", item: UInt64(i)) }
  let reading = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), written = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
  var retained = [Trace]()
  DispatchQueue.global().async { retained = d.snapshot { trace in if trace.item == 0 { reading.signal(); release.wait() }; return true }; finished.signal() }
  guard reading.wait(timeout: .now() + 2) == .success else { release.signal(); return XCTFail("reader did not start") }
  DispatchQueue.global().async { d.mark("input.raw", item: 32768); written.signal() }
  let result = written.wait(timeout: .now() + 0.25)
  release.signal(); _ = finished.wait(timeout: .now() + 2); if result != .success { _ = written.wait(timeout: .now() + 2) }
  XCTAssertEqual(result, .success, "slow diagnostics consumption held the Pencil writer lock")
  XCTAssertEqual(retained.map(\.item), Array(0..<32768).map(UInt64.init), "retained export changed while the ring was overwritten")
  XCTAssertEqual(d.report().traces.last?.item, 32768)
 }
 func testDiagnosticRingWrapAcrossPartialStorageBlock() {
  let d = Diagnostics(capacity: 129); for i in 1...300 { d.mark("input.raw", item: UInt64(i)) }
  let r = d.report(after: 250); XCTAssertEqual(d.snapshot().map(\.ordinal), Array(172...300).map(UInt64.init)); XCTAssertEqual(r.traces.map(\.ordinal), Array(251...300).map(UInt64.init)); XCTAssertEqual(r.totalRecords, 300); XCTAssertEqual(r.counters["input.raw"], 300)
 }
 func testUniqueExport() throws { let root = FileManager.default.temporaryDirectory.appendingPathComponent("padink-test-diagnostics-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }; let d = Diagnostics(); d.mark("input.post"); let a = try d.export(to: root), b = try d.export(to: root); XCTAssertNotEqual(a, b); XCTAssertTrue(FileManager.default.fileExists(atPath: a.path)) }
 func testIntervalDistribution() { let d = Distribution([1, 2, 3, 4, 100]); XCTAssertEqual(d.p50, 3); XCTAssertEqual(d.max, 100) }
 func testFPSUsesOnlyRecentActualPresentations() { let d = Diagnostics(); d.mark("video.presented", time: 1); d.mark("video.renderSubmitted", time: 3_000_000_000); d.mark("video.presented", time: 3_000_000_000); XCTAssertEqual(d.fps("video.presented", now: 3_000_000_001), 0.5) }
}

final class ActualCaptureTests: XCTestCase {
 func p(_ t: UInt64, _ x: Float) -> ActualPoint { ActualPoint(timestamp: t, x: x, y: 0.5, pressure: 0.6, altitude: 1, azimuth: 0) }
 func testBeginCoalescedAndTerminalActualEndpoint() throws { var capture = PencilCapture(); var samples = capture.capture([p(1, 0.1), p(2, 0.2)], callback: .begin); samples += capture.capture([p(2, 0.2), p(3, 0.3), p(4, 0.4)], callback: .end); XCTAssertEqual(samples.map(\.x), [0.1, 0.2, 0.3, 0.4]); XCTAssertEqual(samples.map(\.phase), [1, 2, 2, 3]); var input = InputSession(); _ = try input.consume(samples); XCTAssertNil(input.active) }
 func testStationaryTerminalIsNeverLost() { var c = PencilCapture(); _ = c.capture([p(1, 0.5)], callback: .begin); let end = c.capture([p(1, 0.5)], callback: .end); XCTAssertEqual(end.count, 1); XCTAssertEqual(end[0].phase, 3); XCTAssertEqual(end[0].sequence, 2) }
 func testSameTimestampDifferentActualContentPreserved() { var c = PencilCapture(); let samples = c.capture([p(1, 0.4), p(1, 0.5)], callback: .begin); XCTAssertEqual(samples.count, 2) }
 func testDisconnectCannotContinueStroke() { var c = PencilCapture(); _ = c.capture([p(1, 0.5)], callback: .begin); c.reset(); XCTAssertTrue(c.capture([p(2, 0.6)], callback: .move).isEmpty); let next = c.capture([p(3, 0.7)], callback: .begin); XCTAssertEqual(next[0].sequence, 1); XCTAssertEqual(next[0].stroke, 2) }
 func testCancelIncludesActualCoalescedSamples() { var c = PencilCapture(); _ = c.capture([p(1, 0.1)], callback: .begin); let samples = c.capture([p(2, 0.2), p(3, 0.3)], callback: .cancel); XCTAssertEqual(samples.map(\.phase), [2, 4]); XCTAssertFalse(c.active) }
 /// Every captured stroke must be encodable as PINK/2 batches end to end.
 func testCapturedStrokeRoundTripsThroughWire() throws { var c = PencilCapture(); var s = c.capture([p(1, 0.1), p(2, 0.2)], callback: .begin, geometryGeneration: 4); s += c.capture([p(3, 0.3)], callback: .end, geometryGeneration: 4); XCTAssertEqual(try PencilBatch(PencilBatch(s).encoded()).pencilSamples, s) }
}

final class IncrementalDiagnosticTests: XCTestCase {
 func testExportOrdinalsPreserveLateTimestamps() { let d = Diagnostics(capacity: 5); d.mark("a", time: 100); let first = d.report(); d.mark("b", time: 50); let next = d.report(after: first.traces.last!.ordinal); XCTAssertEqual(next.traces.map(\.stage), ["b"]); XCTAssertGreaterThan(next.traces[0].ordinal, first.traces[0].ordinal) }
 func testRingWindowHasStableOrdinals() { let d = Diagnostics(capacity: 2); d.mark("a"); d.mark("b"); d.mark("c"); XCTAssertEqual(d.report().traces.map(\.ordinal), [2, 3]); XCTAssertTrue(d.report(after: 3).traces.isEmpty) }
}

final class StrokeGeometryTests: XCTestCase {
 let first = VideoGeometry(source: CGSize(width: 2360, height: 1534), bounds: CGRect(x: 0, y: 0, width: 1180, height: 820))
 func testKnownCoordinatesWithoutInverseTransform() throws {
  // Independent measured fixture: video spans y=26.5...793.5 in UIKit points.
  let cases: [(CGPoint, CGPoint)] = [(CGPoint(x: 0, y: 26.5), .zero), (CGPoint(x: 590, y: 410), CGPoint(x: 0.5, y: 0.5)), (CGPoint(x: 295, y: 218.25), CGPoint(x: 0.25, y: 0.25)), (CGPoint(x: 885, y: 601.75), CGPoint(x: 0.75, y: 0.75)), (CGPoint(x: 0, y: 410), CGPoint(x: 0, y: 0.5)), (CGPoint(x: 590, y: 26.5), CGPoint(x: 0.5, y: 0))]
  for (point, expected) in cases { let p = try XCTUnwrap(first.normalized(point)); XCTAssertEqual(p.x, expected.x, accuracy: 1e-9); XCTAssertEqual(p.y, expected.y, accuracy: 1e-9) }
  XCTAssertNil(first.normalized(CGPoint(x: 590, y: 20))); XCTAssertNil(first.normalized(CGPoint(x: 590, y: 800)))
 }
 func testLayoutChangeCancelsAndRejectsOldPresentation() throws {
  var g = PencilGeometryState(); XCTAssertFalse(g.update(first, orientation: 4)); let old = g.generation
  XCTAssertNil(g.begin(CGPoint(x: 590, y: 410))); g.presented(generation: old); XCTAssertNotNil(g.begin(CGPoint(x: 590, y: 410)))
  let changed = VideoGeometry(source: first.source, bounds: CGRect(x: 0, y: 0, width: 1000, height: 820))
  XCTAssertTrue(g.update(changed, orientation: 4)); XCTAssertFalse(g.active); XCTAssertNil(g.map(CGPoint(x: 590, y: 410)))
  g.presented(generation: old); XCTAssertNil(g.begin(CGPoint(x: 500, y: 410)))
  g.presented(generation: g.generation); XCTAssertEqual(g.begin(CGPoint(x: 500, y: 410)), CGPoint(x: 0.5, y: 0.5))
 }
 func testOverlayKeepsRevisionButSameSizeRotationCancels() {
  var g = PencilGeometryState(); g.update(first, orientation: 4); g.presented(generation: g.generation); _ = g.begin(CGPoint(x: 590, y: 410)); let rev = g.generation
  XCTAssertFalse(g.update(first, orientation: 4)); XCTAssertEqual(g.generation, rev); XCTAssertTrue(g.active)
  XCTAssertTrue(g.update(first, orientation: 3)); XCTAssertFalse(g.ready); XCTAssertGreaterThan(g.generation, rev)
 }
 func testGeometryRevisionEncodedInKnownByteOrderAndMixedStrokeRejected() throws {
  var s = PencilSample(stroke: 1, sequence: 1, timestamp: 1, x: 0.5, y: 0.5, pressure: 0.5, altitude: 1, azimuth: 0, phase: .begin, geometryGeneration: 0x1234_5678)
  let bytes = try PencilBatch([s]).encoded(); XCTAssertEqual(Array(bytes[8..<12]), [0x12, 0x34, 0x56, 0x78]); XCTAssertEqual(try PencilBatch(bytes).pencilSamples.first?.geometryGeneration, 0x1234_5678)
  var input = InputSession(); _ = try input.consume([s]); s.sequence = 2; s.phase = PencilPhase.move.rawValue; s.geometryGeneration += 1
  XCTAssertThrowsError(try input.consume([s])); XCTAssertEqual(input.active?.sequence, 1)
 }
 func testGeometryCancellationKeepsLastActualEndpointOnce() throws {
  var c = PencilCapture(); let p = ActualPoint(timestamp: 123, x: 0.8, y: 0.6, pressure: 0.5, altitude: 1, azimuth: 0)
  let begin = c.capture([p], callback: .begin, geometryGeneration: 9); let cancel = try XCTUnwrap(c.cancel())
  XCTAssertEqual(cancel.x, begin[0].x); XCTAssertEqual(cancel.y, begin[0].y); XCTAssertEqual(cancel.geometryGeneration, 9); XCTAssertEqual(cancel.sequence, 2); XCTAssertEqual(cancel.phase, PencilPhase.cancel.rawValue); XCTAssertNil(c.cancel())
  XCTAssertTrue(c.capture([p], callback: .move, geometryGeneration: 10).isEmpty)
 }
 func testPressureChangesAtSamePositionAreNotDeduplicated() {
  var c = PencilCapture(); let a = ActualPoint(timestamp: 1, x: 0.5, y: 0.5, pressure: 0.2, altitude: 1, azimuth: 0)
  var b = a; b.pressure = 0.8
  XCTAssertEqual(c.capture([a, b], callback: .begin).map(\.pressure), [0.2, 0.8])
 }
 /// 0.3 addition (REWRITE_BRIEF §6.5): primary display with a negative global origin.
 func testMacMappingUsesGlobalCaptureBoundsIncludingNegativeOrigin() {
  let bounds = CGRect(x: -1470, y: -956, width: 1470, height: 956)
  XCTAssertEqual(VideoGeometry.macPoint(normalized: .zero, captureBounds: bounds), CGPoint(x: -1470, y: -956))
  XCTAssertEqual(VideoGeometry.macPoint(normalized: CGPoint(x: 0.5, y: 0.5), captureBounds: bounds), CGPoint(x: -735, y: -478))
  XCTAssertEqual(VideoGeometry.macPoint(normalized: CGPoint(x: 1, y: 1), captureBounds: CGRect(x: 0, y: 0, width: 1470, height: 956)), CGPoint(x: 1470, y: 956))
 }
}
