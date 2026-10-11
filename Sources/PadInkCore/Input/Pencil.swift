import Foundation

public enum PencilPhase: UInt8 { case begin = 1, move, end, cancel }

/// One actual UIKit Pencil sample. Semantics are Baseline v0.1.0's (real-device verified with
/// PowerPoint native ink); only the wire layout moved to `PencilBatch` (PINK/2 §4.3).
public struct PencilSample: Equatable, Codable {
 /// Gesture identity: monotonically increasing per iPad app lifetime.
 public var stroke: UInt64, sequence: UInt64, timestamp: UInt64
 public var x: Float, y: Float, pressure: Float, altitude: Float, azimuth: Float
 public var phase: UInt8, flags: UInt8
 /// Presented-geometry generation the stroke started on; constant for the whole stroke.
 public var geometryGeneration: UInt32
 public init(stroke: UInt64, sequence: UInt64, timestamp: UInt64, x: Float, y: Float, pressure: Float, altitude: Float, azimuth: Float, phase: PencilPhase, flags: UInt8 = 0, geometryGeneration: UInt32 = 1) {
  self.stroke = stroke; self.sequence = sequence; self.timestamp = timestamp; self.x = x; self.y = y; self.pressure = pressure
  self.altitude = altitude; self.azimuth = azimuth; self.phase = phase.rawValue; self.flags = flags; self.geometryGeneration = geometryGeneration
 }
 /// Per-axis normalized tilt from actual altitude/azimuth; UIKit's downward y becomes macOS tablet y sign.
 public var tilt: (Double, Double) { let magnitude = cos(Double(altitude)); let z = sin(Double(altitude)); return (atan2(magnitude * cos(Double(azimuth)), z) / (Double.pi / 2), -atan2(magnitude * sin(Double(azimuth)), z) / (Double.pi / 2)) }
 public func validate() throws {
  guard stroke != 0, sequence != 0, sequence <= UInt64(UInt32.max), geometryGeneration != 0, [x, y, pressure, altitude, azimuth].allSatisfy({ $0.isFinite }), (0...1).contains(x), (0...1).contains(y), (0...1).contains(pressure), (0...Float.pi / 2 + 0.001).contains(altitude), abs(azimuth) <= 2 * Float.pi + 0.001, PencilPhase(rawValue: phase) != nil, flags & ~1 == 0 else { throw PencilPayloadError.value }
 }
}

public extension PencilBatch {
 /// One wire batch for consecutive samples of one stroke on one geometry generation.
 init(_ samples: [PencilSample]) throws {
  guard let first = samples.first else { throw PencilPayloadError.count }
  guard samples.allSatisfy({ $0.stroke == first.stroke && $0.geometryGeneration == first.geometryGeneration }) else { throw PencilPayloadError.identity }
  try samples.forEach { try $0.validate() }
  self.init(gestureID: first.stroke, geometryGeneration: first.geometryGeneration, samples: samples.map {
   PencilWireSample(sequence: UInt32($0.sequence), timestamp: $0.timestamp, x: $0.x, y: $0.y, pressure: $0.pressure, altitude: $0.altitude, azimuth: $0.azimuth, phase: PencilWirePhase(rawValue: $0.phase)!, estimated: $0.flags & 1 != 0)
  })
  try validate()
 }
 var pencilSamples: [PencilSample] {
  samples.map { PencilSample(stroke: gestureID, sequence: UInt64($0.sequence), timestamp: $0.timestamp, x: $0.x, y: $0.y, pressure: $0.pressure, altitude: $0.altitude, azimuth: $0.azimuth, phase: PencilPhase(rawValue: $0.phase.rawValue)!, flags: $0.estimated ? 1 : 0, geometryGeneration: geometryGeneration) }
 }
}

public enum TabletAction: Equatable { case proximityIn, down(PencilSample), move(PencilSample), up(PencilSample), proximityOut }

public enum PencilSequenceError: Error, Equatable { case sequence }

/// Transactional batch validation: invalid batches cause no partial input injection. (Baseline)
public struct InputSession {
 public private(set) var active: PencilSample?
 private var completedStroke: UInt64 = 0
 public init() {}
 public mutating func consume(_ samples: [PencilSample]) throws -> [TabletAction] {
  var next = self; var actions = [TabletAction]()
  for s in samples {
   try s.validate()
   switch PencilPhase(rawValue: s.phase)! {
   case .begin:
    guard next.active == nil, s.sequence == 1, s.stroke > next.completedStroke else { throw PencilSequenceError.sequence }
    next.active = s; actions += [.proximityIn, .down(s)]
   case .move, .end, .cancel:
    guard let a = next.active, a.stroke == s.stroke, a.sequence + 1 == s.sequence, s.timestamp >= a.timestamp, a.geometryGeneration == s.geometryGeneration else { throw PencilSequenceError.sequence }
    if s.phase == PencilPhase.move.rawValue { actions.append(.move(s)); next.active = s }
    else { actions.append(.up(s)); actions.append(.proximityOut); next.active = nil; next.completedStroke = s.stroke }
   }
  }
  self = next; return actions
 }
 /// Safe release at the last actual sample; idempotent. Clears the completed-stroke floor as in
 /// Baseline: stroke IDs restart at 1 when the iPad app relaunches, and stale strokes from an
 /// older connection are rejected by session generation instead.
 public mutating func reset() -> [TabletAction] {
  defer { active = nil; completedStroke = 0 }
  guard let s = active else { return [] }
  return [.up(s), .proximityOut]
 }
}
