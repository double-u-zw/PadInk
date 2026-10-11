import Foundation
import CoreGraphics

public struct FingerPoint: Equatable {
 public let id: UInt64, point: CGPoint
 public init(_ id: UInt64, _ point: CGPoint) { self.id = id; self.point = point }
}
public struct TouchAction: Equatable {
 public let id: UInt64, sequence: UInt32, timestamp: UInt64, kind: TouchKind, phase: TouchPhase, point: CGPoint, delta: CGPoint, clicks: UInt8
}
/// iPad-only classification decisions, driven by deterministic snapshots and a monotonic clock.
/// UIKit points stay here; the single VideoGeometry maps emitted actions at the app boundary.
public struct GestureFSM {
 public enum State: String { case idle, fingerTapCandidate, fingerDragging, twoFingerCandidate, scrolling, pinching, pencilActive, cancelling }
 public private(set) var state: State = .idle
 public private(set) var active: (UInt64, UInt32)?
 public var confirmationWindow: UInt64 = 80_000_000
 public var dragThreshold: CGFloat = 6, scrollThreshold: CGFloat = 3, pinchThreshold: CGFloat = 0.06
 public var touchEnabled = false
 private var fingers: [FingerPoint] = [], origin = CGPoint.zero, last = CGPoint.zero, baselineDistance: CGFloat = 0, lastDistance: CGFloat = 0
 // One callback can move only one finger; allow its partner one frame to catch up.
 private var twoFingerOrigin: [FingerPoint] = [], settleAt: UInt64?
 private let snapshotGrace: UInt64 = 20_000_000
 private var beganAt: UInt64 = 0, clock: UInt64 = 0, nextID: UInt64 = 1 << 63, seq: UInt32 = 0
 private var pencil = false, hover = false, blocked = false
 private var pendingTaps: [(CGPoint, UInt64)] = [], lastTap: (CGPoint, UInt64)?, clicks: UInt8 = 1
 public init() {}
 public var deadline: UInt64? {
  let candidate = (state == .fingerTapCandidate || state == .twoFingerCandidate) && clock < beganAt + confirmationWindow ? beganAt + confirmationWindow : nil
  let settling = state == .twoFingerCandidate ? settleAt.flatMap { clock < $0 ? $0 : nil } : nil
  return [candidate, settling, pendingTaps.first?.1].compactMap { $0 }.min()
 }
 public mutating func update(_ points: [FingerPoint], now: UInt64) -> [TouchAction] {
  clock = max(clock, now)
  let prior = touchEnabled && !pencil && !hover && !blocked ? flushTap(now: clock) : []
  return prior + process(points, now: clock)
 }
 private mutating func process(_ points: [FingerPoint], now: UInt64) -> [TouchAction] {
  clock = max(clock, now); let points = points.sorted { $0.id < $1.id }, old = fingers; fingers = points
  if !touchEnabled || pencil || hover || blocked {
   let out = cancel(now: clock)
   if points.isEmpty { blocked = false; state = pencil || hover ? .pencilActive : .idle }
   return out
  }
  if points.count > 2 { blocked = true; return cancel(now: clock) }
  if old.isEmpty, !points.isEmpty {
   var out = flushTap(now: clock)
   beganAt = clock; origin = center(points); last = origin; baselineDistance = distance(points); lastDistance = baselineDistance
   twoFingerOrigin = points; settleAt = nil
   state = points.count == 1 ? .fingerTapCandidate : .twoFingerCandidate
   out += classify(now: clock); return out
  }
  if !old.isEmpty, points.isEmpty {
   if state == .fingerTapCandidate, clock - beganAt <= 400_000_000, length(last, origin) < dragThreshold {
    pendingTaps.append((last, beganAt + confirmationWindow)); state = .idle; return flushTap(now: clock)
   }
   let out = finish(.ended, now: clock); state = .idle; return out
  }
  if points.count != old.count || zip(points, old).contains(where: { $0.id != $1.id }) {
   // Two fingers rarely lift in the same UIKit callback. The first normal lift
   // ends scrolling/pinching; the held finger stays blocked until all lift.
   // UIKit/system cancellation has already gone through cancel(now:).
   let normalLift = old.count == 2 && points.count == 1 && old.contains(where: { $0.id == points[0].id }) &&
     (state == .scrolling || state == .pinching)
   let out = finish(normalLift ? .ended : .cancelled, now: clock)
   if points.count == 2 { beganAt = clock; twoFingerOrigin = points; settleAt = nil; state = .twoFingerCandidate; origin = center(points); last = origin; baselineDistance = distance(points); lastDistance = baselineDistance }
   else if points.count == 1 { blocked = true; state = .cancelling }
   return out
  }
  return classify(now: clock)
 }
 public mutating func timer(now: UInt64) -> [TouchAction] { clock = max(clock, now); if pencil || hover || blocked || !touchEnabled { return [] }; return flushTap(now: clock) + classify(now: clock) }
 public mutating func setPencil(_ present: Bool, hover: Bool = false, now: UInt64) -> [TouchAction] {
  let wasPresent = pencil || self.hover
  if hover { self.hover = present } else { pencil = present }
  if pencil || self.hover { blocked = !fingers.isEmpty; let out = cancel(now: now); state = .pencilActive; return out }
  if wasPresent { state = blocked ? .cancelling : .idle }; return []
 }
 public mutating func cancel(now: UInt64) -> [TouchAction] {
  pendingTaps.removeAll(); let out = finish(.cancelled, now: max(clock, now)); blocked = !fingers.isEmpty
  state = blocked ? .cancelling : .idle; return out
 }
 public mutating func reset() { let enabled = touchEnabled; self = GestureFSM(); touchEnabled = enabled }
 private mutating func classify(now: UInt64) -> [TouchAction] {
  guard !fingers.isEmpty else { return [] }
  let point = center(fingers), d = distance(fingers)
  switch state {
  case .fingerTapCandidate:
   last = point
   guard now >= beganAt + confirmationWindow, length(point, origin) >= dragThreshold else { return [] }
   state = .fingerDragging; clicks = 1
   return [begin(.pointer, point: origin, now: now), emit(.pointer, .changed, point: point, now: now)]
  case .twoFingerCandidate:
   guard now >= beganAt + confirmationWindow else { return [] }
   let translation = length(point, origin), radial = abs(d - baselineDistance) / 2
   let moved = zip(fingers, twoFingerOrigin).filter { length($0.point, $1.point) > 0.01 }.count
   if moved == 1 {
    if settleAt == nil { settleAt = now + snapshotGrace }
    guard now >= settleAt! else { return [] }
   }
   if baselineDistance > 0, abs(d / baselineDistance - 1) >= pinchThreshold, radial >= translation {
    state = .pinching; lastDistance = d; last = point
    return [begin(.magnify, point: origin, now: now), emit(.magnify, .changed, point: point, delta: CGPoint(x: log(d / baselineDistance), y: 0), now: now)]
   }
   if translation >= scrollThreshold, translation > radial {
    state = .scrolling; last = point
    return [begin(.scroll, point: origin, now: now), emit(.scroll, .changed, point: point, delta: CGPoint(x: point.x - origin.x, y: point.y - origin.y), now: now)]
   }
  case .fingerDragging:
   guard point != last else { return [] }; last = point; return [emit(.pointer, .changed, point: point, now: now)]
  case .scrolling:
   let delta = CGPoint(x: point.x - last.x, y: point.y - last.y); last = point
   if delta != .zero { return [emit(.scroll, .changed, point: point, delta: delta, now: now)] }
  case .pinching:
   guard d > 0, lastDistance > 0, (d != lastDistance || point != last) else { return [] }
   let scale = log(d / lastDistance); lastDistance = d; last = point
   return [emit(.magnify, .changed, point: point, delta: CGPoint(x: scale, y: 0), now: now)]
  default: break
  }
  return []
 }
 private mutating func flushTap(now: UInt64) -> [TouchAction] {
  var out: [TouchAction] = []
  while let tap = pendingTaps.first, now >= tap.1 {
   pendingTaps.removeFirst()
   clicks = lastTap.map { now >= $0.1 && now - $0.1 <= 300_000_000 && length(tap.0, $0.0) <= 12 ? 2 : 1 } ?? 1
   lastTap = clicks == 2 ? nil : (tap.0, now)
   out += [begin(.pointer, point: tap.0, now: now), emit(.pointer, .ended, point: tap.0, now: now)]; active = nil
  }
  return out
 }
 private mutating func begin(_ kind: TouchKind, point: CGPoint, now: UInt64) -> TouchAction { nextID &+= 1; seq = 0; active = (nextID, seq); return emit(kind, .began, point: point, now: now) }
 private mutating func emit(_ kind: TouchKind, _ phase: TouchPhase, point: CGPoint, delta: CGPoint = .zero, now: UInt64) -> TouchAction {
  seq += 1; active = (nextID, seq)
  return TouchAction(id: nextID, sequence: seq, timestamp: now, kind: kind, phase: phase, point: point, delta: delta, clicks: kind == .pointer ? clicks : 1)
 }
 private mutating func finish(_ phase: TouchPhase, now: UInt64) -> [TouchAction] {
  guard active != nil else { return [] }; defer { active = nil }
  let kind: TouchKind = state == .scrolling ? .scroll : state == .pinching ? .magnify : .pointer
  return [emit(kind, phase, point: last, now: now)]
 }
 private func center(_ p: [FingerPoint]) -> CGPoint { p.isEmpty ? last : CGPoint(x: p.reduce(0) { $0 + $1.point.x } / CGFloat(p.count), y: p.reduce(0) { $0 + $1.point.y } / CGFloat(p.count)) }
 private func distance(_ p: [FingerPoint]) -> CGFloat { p.count == 2 ? length(p[0].point, p[1].point) : 0 }
 private func length(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
