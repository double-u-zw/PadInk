#if os(macOS)
import Foundation
import PadInkCore

/// Recorded real Pencil strokes for the Mac-side replay (REWRITE_BRIEF §11.1).
public struct ReplayFixture: Codable, Equatable {
 public var source: String
 public var strokes: [[PencilSample]]

 /// Imports 0.2.0's Research/MacZoom/extract-replay.py output (Baseline `input.raw` traces of real
 /// iPad writing). Only complete strokes are kept; stroke IDs are renumbered 1...n and the geometry
 /// generation set to 1 so the replay can present a single geometry.
 public static func importExtractReplay(_ data: Data, source: String) throws -> ReplayFixture {
  struct Raw: Decodable { let complete: [Group] }
  struct Group: Decodable { let samples: [S] }
  struct S: Decodable { let sequence: UInt64; let timestamp: UInt64; let x, y, pressure, altitude, azimuth: Float; let phase: UInt8; let flags: UInt8? }
  let raw = try JSONDecoder().decode(Raw.self, from: data)
  let strokes = raw.complete.enumerated().map { index, g in g.samples.map { s in
   var p = PencilSample(stroke: UInt64(index + 1), sequence: s.sequence, timestamp: s.timestamp, x: s.x, y: s.y, pressure: s.pressure, altitude: s.altitude, azimuth: s.azimuth, phase: PencilPhase(rawValue: s.phase) ?? .move, flags: (s.flags ?? 0) & 1, geometryGeneration: 1)
   p.phase = s.phase; return p
  } }
  return ReplayFixture(source: source, strokes: strokes)
 }

 /// Batches as the iPad would send them: the begin sample alone (Baseline), then samples grouped
 /// into windows of `window` ns (≈ one UIKit callback of coalesced samples at 120 Hz), ≤ 256 each.
 public static func batches(_ stroke: [PencilSample], window: UInt64 = 8_333_333) -> [[PencilSample]] {
  guard let first = stroke.first else { return [] }
  var out = [[first]], current = [PencilSample](), start: UInt64 = 0
  for s in stroke.dropFirst() {
   if current.isEmpty { start = s.timestamp }
   if !current.isEmpty && (s.timestamp &- start >= window || current.count == PencilBatch.maxSamples) { out.append(current); current = []; start = s.timestamp }
   current.append(s)
  }
  if !current.isEmpty { out.append(current) }
  return out
 }
}
#endif
