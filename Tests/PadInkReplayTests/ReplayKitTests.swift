import XCTest
import CoreGraphics
import CryptoKit
import PadInkCore
@testable import PadInkReplayKit

final class InkMLTests: XCTestCase {
 /// The first points of a real PowerPoint trace (Baseline evidence ink80.xml), decoded by hand:
 /// p1 explicit; p2 first differences; p3 second differences; p4 keeps second differences (sticky).
 func testRealPowerPointTraceWithStickyDifferenceQualifiers() throws {
  let points = try InkML.decode("155 110 7533,'0'-66'989,\"0\"23\"-539,24 65-225", channels: 3)
  XCTAssertEqual(points, [[155, 110, 7533], [155, 44, 8522], [155, 1, 8972], [179, 23, 9197]])
 }
 func testExplicitResetRepeatAndSeparators() throws {
  // Qualifiers are per value and sticky per channel: "!100 200" would reset X only.
  XCTAssertEqual(try InkML.decode("10 20,'1'2,3 4,!100 !200,* 5", channels: 2), [[10, 20], [11, 22], [14, 26], [100, 200], [100, 5]])
  XCTAssertEqual(try InkML.decode("10 20,'1'2,!100 200", channels: 2), [[10, 20], [11, 22], [100, 222]])
  XCTAssertEqual(try InkML.decode("1-2,3-4", channels: 2), [[1, -2], [3, -4]])
  XCTAssertThrowsError(try InkML.decode("1 2 3", channels: 2))
  XCTAssertThrowsError(try InkML.decode("1 ?", channels: 2))
 }
 func testDocumentWithChannelsAndSeveralTraces() throws {
  let xml = "<inkml:ink><inkml:traceFormat><inkml:channel name=\"X\"/><inkml:channel name=\"Y\"/></inkml:traceFormat><inkml:trace contextRef=\"#c\">0 0,'5'5</inkml:trace><inkml:trace>7 7</inkml:trace></inkml:ink>"
  let traces = try InkML.traces(Data(xml.utf8))
  XCTAssertEqual(traces.map(\.xy), [[CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)], [CGPoint(x: 7, y: 7)]])
 }
}

final class ComparisonTests: XCTestCase {
 let truth = Affine2D(a: 0.02, b: 0.001, c: -0.001, d: 0.02, tx: 3, ty: -7)
 func testAffineFitRecoversKnownTransformAndRejectsCollinear() throws {
  let src = [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0), CGPoint(x: 0, y: 800), CGPoint(x: 400, y: 300)]
  let fit = try XCTUnwrap(Affine2D.fit(src, src.map(truth.apply)))
  let got: [Double] = [fit.a, fit.b, fit.c, fit.d, fit.tx, fit.ty]
  let want: [Double] = [truth.a, truth.b, truth.c, truth.d, truth.tx, truth.ty]
  for i in 0..<6 { XCTAssertEqual(got[i], want[i], accuracy: 1e-9) }
  XCTAssertNil(Affine2D.fit([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)], [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]))
 }
 private func strokes() -> [[CGPoint]] {
  var out = [[CGPoint]]()
  for i in 0..<6 {
   var stroke = [CGPoint]()
   for k in 0...40 {
    let x: Double = 100 + Double(i) * 80 + 30 * sin(Double(k) / 6)
    let y: Double = 100 + Double(k) * 5 + Double(i * 10)
    stroke.append(CGPoint(x: x, y: y))
   }
   out.append(stroke)
  }
  return out
 }
 func testResampledFaithfulInkHasNearZeroDeviation() throws {
  let injected = strokes()
  // The app keeps every other point and stores ink in its own units.
  var saved = [[CGPoint]]()
  for s in injected {
   var kept = [CGPoint]()
   for (k, point) in s.enumerated() where k % 2 == 0 || k == s.count - 1 { kept.append(truth.apply(point)) }
   saved.append(kept)
  }
  let r = try XCTUnwrap(StrokeComparison.compare(injected: injected, saved: saved))
  // Dropping every other point of a curve leaves only chord error (< 0.5 pt here); endpoints are exact.
  XCTAssertTrue(r.countsMatch); XCTAssertLessThan(r.deviation.max, 0.5); XCTAssertLessThan(r.endpointError.max, 1e-6); XCTAssertTrue(r.deformedStrokes.isEmpty)
  XCTAssertEqual(r.pointRatio.p50, 21.0 / 41.0, accuracy: 1e-9)
 }
 /// A local deformation in one stroke (P1-like) is reported for that stroke only.
 func testLocalDeformationIsDetectedPerStroke() throws {
  let injected = strokes()
  var saved = injected.map { $0.map(truth.apply) }
  saved[3][20] = truth.apply(CGPoint(x: injected[3][20].x + 12, y: injected[3][20].y))
  let r = try XCTUnwrap(StrokeComparison.compare(injected: injected, saved: saved))
  XCTAssertEqual(r.deformedStrokes, [3]); XCTAssertGreaterThan(r.strokes[3].maxDeviation, 5)
 }
 func testMissingStrokeShowsInCounts() throws {
  let injected = strokes(); let saved = Array(injected.dropLast()).map { $0.map(truth.apply) }
  let r = try XCTUnwrap(StrokeComparison.compare(injected: injected, saved: saved))
  XCTAssertFalse(r.countsMatch); XCTAssertEqual(r.savedStrokes, 5)
 }
}

final class FixtureTests: XCTestCase {
 static let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/replay/baseline-real-strokes.json")
 static let persistenceURL = fixtureURL.deletingLastPathComponent().appendingPathComponent("persistence", isDirectory: true)
 func testPersistenceFixturesMatchRecordedSHA256() throws {
  struct Fixture: Decodable { let path: String, bytes: Int, sha256: String }
  struct Manifest: Decodable { let schemaVersion: Int, fixtures: [Fixture] }
  let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.persistenceURL.appendingPathComponent("manifest.json")))
  let expected = Set(["baseline-0.1", "replay-hid", "replay-private"].flatMap { group in
   ["before-reopen.pptx", "after-reopen.pptx"].map { "\(group)/\($0)" }
  })
  XCTAssertEqual(manifest.schemaVersion, 1)
  XCTAssertEqual(manifest.fixtures.count, 6)
  XCTAssertEqual(Set(manifest.fixtures.map(\.path)), expected)
  for fixture in manifest.fixtures {
   let data = try Data(contentsOf: Self.persistenceURL.appendingPathComponent(fixture.path))
   XCTAssertEqual(data.count, fixture.bytes, fixture.path)
   let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
   XCTAssertEqual(sha256, fixture.sha256, fixture.path)
  }
 }
 func testPenFloatingWindowBeforeDocumentDoesNotMoveReplayOffCanvas() {
  let floating = CGRect(x: 0, y: 0, width: 64, height: 96)
  let document = CGRect(x: 0, y: 25, width: 1470, height: 844)
  XCTAssertEqual(ReplayWindow.documentBounds(in: [floating, document]), document)
  XCTAssertNil(ReplayWindow.documentBounds(in: [floating]))
 }
 func testEqualSizeDocumentsKeepFrontmostOrder() {
  let front = CGRect(x: 100, y: 100, width: 900, height: 600)
  let back = CGRect(x: 200, y: 200, width: 900, height: 600)
  XCTAssertEqual(ReplayWindow.documentBounds(in: [front, back]), front)
 }
 func testBaselineFixtureReplaysAsValidWireBatches() throws {
  let fixture = try JSONDecoder().decode(ReplayFixture.self, from: Data(contentsOf: Self.fixtureURL))
  XCTAssertEqual(fixture.strokes.count, 85); XCTAssertEqual(fixture.strokes.reduce(0) { $0 + $1.count }, 7143)
  XCTAssertTrue(fixture.source.contains("5c66605"))
  var session = InputSession(), batchCount = 0
  for stroke in fixture.strokes {
   let batches = ReplayFixture.batches(stroke)
   XCTAssertEqual(batches.first?.count, 1); XCTAssertEqual(batches.first?.first?.phase, PencilPhase.begin.rawValue)
   XCTAssertEqual(batches.flatMap { $0 }, stroke, "batching must not drop, reorder or alter samples")
   for b in batches { batchCount += 1; let wire = try PencilBatch(PencilBatch(b).encoded()); _ = try session.consume(wire.pencilSamples) }
   XCTAssertNil(session.active)
  }
  XCTAssertGreaterThan(batchCount, 85 * 2)
 }
 func testBatchingWindowAndLimit() {
  var s = [PencilSample]()
  for i in 1...600 {
   let phase: PencilPhase = i == 1 ? .begin : (i == 600 ? .end : .move)
   s.append(PencilSample(stroke: 1, sequence: UInt64(i), timestamp: UInt64(i) * 1_000, x: 0, y: 0, pressure: 0, altitude: 0, azimuth: 0, phase: phase))
  }
  let b = ReplayFixture.batches(s)
  XCTAssertTrue(b.allSatisfy { $0.count <= PencilBatch.maxSamples }); XCTAssertEqual(b.flatMap { $0 }, s)
 }
}

/// Re-checks the committed Baseline B-003 fixtures on every machine.
final class BaselineEvidenceTests: XCTestCase {
 let dir = FixtureTests.persistenceURL.appendingPathComponent("baseline-0.1", isDirectory: true)
 func testBaselinePowerPointInkDecodesAndPersistedByteIdentical() throws {
  let before = dir.appendingPathComponent("before-reopen.pptx"), after = dir.appendingPathComponent("after-reopen.pptx")
  let a = try PPTXInk.parts(of: before), b = try PPTXInk.parts(of: after)
  XCTAssertEqual(a.count, 81); XCTAssertEqual(b.count, 81)
  XCTAssertEqual(a.map(\.data), b.map(\.data), "native ink must survive save -> close -> reopen byte for byte")
  XCTAssertTrue(a.allSatisfy { $0.traces.count == 1 && $0.traces[0].points.count >= 1 && $0.traces[0].points.allSatisfy { $0.allSatisfy(\.isFinite) } })
 }
}
