import Foundation
import CoreGraphics

/// The single mapping used by Pencil (and, from Phase 3, Touch). Moved from Baseline Video.swift
/// (aspect fit, letterbox exclusion, raster selection) and extended with a u32 generation and the
/// Mac side of the mapping. No other module may compute coordinates (REWRITE_BRIEF §6.5).
public struct VideoGeometry: Equatable {
 public var source: CGSize, bounds: CGRect
 public init(source: CGSize, bounds: CGRect) { self.source = source; self.bounds = bounds }
 /// Presented video rect inside the iPad view, in UIKit points.
 public var rect: CGRect {
  guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
  let s = min(bounds.width / source.width, bounds.height / source.height)
  let size = CGSize(width: source.width * s, height: source.height * s)
  return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
 }
 /// iPad point -> normalized [0,1] in the presented video rect. Letterbox points are nil unless clamped.
 public func normalized(_ p: CGPoint, clamp: Bool = false) -> CGPoint? {
  let r = rect; guard r.width > 0, r.height > 0, clamp || r.contains(p) else { return nil }
  return CGPoint(x: min(1, max(0, (p.x - r.minX) / r.width)), y: min(1, max(0, (p.y - r.minY) / r.height)))
 }
 /// UIKit movement -> normalized movement, shared by the Touch wire path.
 public func normalizedDelta(_ delta: CGPoint) -> CGPoint { let r = rect; return r.width > 0 && r.height > 0 ? CGPoint(x: delta.x / r.width, y: delta.y / r.height) : .zero }
 /// Encode raster: even, aspect-preserving, never above source pixels, at most 4096 per axis.
 public static func raster(source: CGSize, drawable: CGSize) -> CGSize {
  let scale = min(1, min(drawable.width / source.width, drawable.height / source.height), min(4096 / source.width, 4096 / source.height))
  return CGSize(width: max(2, floor(source.width * scale / 2) * 2), height: max(2, floor(source.height * scale / 2) * 2))
 }
 /// Extended rasters require the peer capability. All choices use source pixels; never upscale.
 public static func raster(source: CGSize, drawable: CGSize, resolution: VideoResolution, extended: Bool) -> CGSize {
  guard source.width.isFinite, source.height.isFinite, source.width >= 2, source.height >= 2 else { return CGSize(width: 2, height: 2) }
  if resolution == .current { return raster(source: source, drawable: drawable) }
  let limit: Double = resolution == .fourK ? 3840 : resolution == .fiveK ? 5120 : 8192
  let scale = min(1, min(extended ? limit : min(limit, 4096), 8192) / max(source.width, source.height))
  return CGSize(width: max(2, floor(source.width * scale / 2) * 2), height: max(2, floor(source.height * scale / 2) * 2))
 }
 /// Normalized -> Quartz global logical points of the captured display. `captureBounds` is
 /// CGDisplayBounds of that display, so a primary display left of or below another display (negative
 /// global origin) maps correctly. No Retina scale is applied here (Baseline-verified).
 public static func macPoint(normalized p: CGPoint, captureBounds: CGRect) -> CGPoint {
  CGPoint(x: captureBounds.minX + p.x * captureBounds.width, y: captureBounds.minY + p.y * captureBounds.height)
 }
}

/// Mapping is usable only after a frame with this exact geometry has presented. (Baseline)
public struct PencilGeometryState {
 public private(set) var generation: UInt32 = 0
 public private(set) var geometry: VideoGeometry?
 public private(set) var orientation = 0, ready = false, active = false
 public init() {}
 /// Returns true when an active stroke had to be cancelled by the change.
 @discardableResult public mutating func update(_ geometry: VideoGeometry, orientation: Int) -> Bool {
  guard self.geometry != geometry || self.orientation != orientation else { return false }
  let cancelled = active; active = false; ready = false
  guard generation < UInt32.max else { self.geometry = nil; return cancelled }
  generation += 1; self.geometry = geometry; self.orientation = orientation; return cancelled
 }
 public mutating func presented(generation: UInt32) { if generation == self.generation, geometry != nil { ready = true } }
 public mutating func begin(_ point: CGPoint) -> CGPoint? {
  guard ready, !active, let p = geometry?.normalized(point) else { return nil }; active = true; return p
 }
 public func map(_ point: CGPoint) -> CGPoint? { guard active, ready else { return nil }; return geometry?.normalized(point, clamp: true) }
 public mutating func end() { active = false }
}
