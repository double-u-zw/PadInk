#if os(macOS)
import Foundation
import CoreGraphics

/// Least-squares 2D affine map (6 parameters).
public struct Affine2D: Equatable {
 public var a, b, c, d, tx, ty: Double
 public func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: a * p.x + b * p.y + tx, y: c * p.x + d * p.y + ty) }
 /// Fits dst ≈ A·src + t. Needs at least three non-collinear pairs.
 public static func fit(_ src: [CGPoint], _ dst: [CGPoint]) -> Affine2D? {
  guard src.count == dst.count, src.count >= 3 else { return nil }
  // Normal equations for [x y 1] · [a b tx] = X and the same rows for Y.
  var m = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3), rx = [0.0, 0, 0], ry = [0.0, 0, 0]
  for (s, t) in zip(src, dst) {
   let v = [Double(s.x), Double(s.y), 1.0]
   for i in 0..<3 { for j in 0..<3 { m[i][j] += v[i] * v[j] }; rx[i] += v[i] * Double(t.x); ry[i] += v[i] * Double(t.y) }
  }
  guard let px = solve3(m, rx), let py = solve3(m, ry) else { return nil }
  return Affine2D(a: px[0], b: px[1], c: py[0], d: py[1], tx: px[2], ty: py[2])
 }
 static func solve3(_ m: [[Double]], _ r: [Double]) -> [Double]? {
  func det(_ a: [[Double]]) -> Double { a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]) }
  let base = det(m); guard abs(base) > 1e-9 * max(1, abs(m[0][0] * m[1][1] * m[2][2])) else { return nil }
  return (0..<3).map { col in var c = m; for row in 0..<3 { c[row][col] = r[row] }; return det(c) / base }
 }
}

public struct Percentiles: Codable, Equatable {
 public var count: Int, p50: Double, p95: Double, max: Double
 public init(_ values: [Double]) { let v = values.sorted(); func q(_ f: Double) -> Double { v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count - 1) * f))] }; count = v.count; p50 = q(0.5); p95 = q(0.95); max = v.last ?? 0 }
}

/// Compares what was injected (Mac screen points) with what PowerPoint saved (InkML units), stroke by
/// stroke in creation order. The saved ink is mapped into screen points with one affine fitted on all
/// stroke endpoints, so PowerPoint's own slide transform and units do not matter. Point counts may
/// differ (the app resamples), so shape error is measured as distance to the other polyline.
public struct StrokeComparison: Codable, Equatable {
 public struct Stroke: Codable, Equatable {
  public var injectedPoints: Int, savedPoints: Int, startError: Double, endError: Double, maxDeviation: Double, meanDeviation: Double
 }
 public var injectedStrokes: Int, savedStrokes: Int
 public var strokes: [Stroke]
 public var endpointError: Percentiles, deviation: Percentiles, pointRatio: Percentiles
 /// Strokes whose max deviation exceeds `localDeformationThreshold` (P1 candidates).
 public var deformedStrokes: [Int]
 public var localDeformationThreshold: Double
 public var countsMatch: Bool { injectedStrokes == savedStrokes }

 public static func compare(injected: [[CGPoint]], saved: [[CGPoint]], localDeformationThreshold: Double = 3) -> StrokeComparison? {
  let n = min(injected.count, saved.count)
  guard n >= 2 else { return nil }
  var src = [CGPoint](), dst = [CGPoint]()
  for i in 0..<n { guard let a = saved[i].first, let b = saved[i].last, let x = injected[i].first, let y = injected[i].last else { continue }; src += [a, b]; dst += [x, y] }
  guard let map = Affine2D.fit(src, dst) else { return nil }
  var strokes = [Stroke](), endpoints = [Double](), deviations = [Double](), ratios = [Double](), deformed = [Int]()
  for i in 0..<n {
   let inj = injected[i], sav = saved[i].map(map.apply)
   guard let i0 = inj.first, let i1 = inj.last, let s0 = sav.first, let s1 = sav.last else { continue }
   let d = sav.map { distance($0, to: inj) } + inj.map { distance($0, to: sav) }
   let s = Stroke(injectedPoints: inj.count, savedPoints: sav.count, startError: hypot(i0.x - s0.x, i0.y - s0.y), endError: hypot(i1.x - s1.x, i1.y - s1.y), maxDeviation: d.max() ?? 0, meanDeviation: d.isEmpty ? 0 : d.reduce(0, +) / Double(d.count))
   strokes.append(s); endpoints += [s.startError, s.endError]; deviations += d; ratios.append(Double(sav.count) / Double(max(1, inj.count)))
   if s.maxDeviation > localDeformationThreshold { deformed.append(i) }
  }
  return StrokeComparison(injectedStrokes: injected.count, savedStrokes: saved.count, strokes: strokes, endpointError: Percentiles(endpoints), deviation: Percentiles(deviations), pointRatio: Percentiles(ratios), deformedStrokes: deformed, localDeformationThreshold: localDeformationThreshold)
 }

 /// Distance from p to a polyline (a single point counts as a degenerate polyline).
 static func distance(_ p: CGPoint, to line: [CGPoint]) -> Double {
  guard let first = line.first else { return .infinity }
  if line.count == 1 { return hypot(p.x - first.x, p.y - first.y) }
  var best = Double.infinity
  for (a, b) in zip(line, line.dropFirst()) {
   let dx = b.x - a.x, dy = b.y - a.y, len = dx * dx + dy * dy
   let t = len > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len)) : 0
   best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
  }
  return best
 }
}
#endif
