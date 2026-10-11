import Foundation

/// Debug-only timing metadata. No coordinates, pressure, document or device names.
public struct PerformanceEvent: Codable {
 public var stage: String, time: UInt64, generation: UInt64
 public var attachment: UUID?, link: UUID?, stream: UInt8?, frame: UInt64?, item: UInt64?, sample: UInt64?
 public var start: UInt64?, end: UInt64?, depth: Int?, bytes: Int?, count: Int?, code: String?
 public var t1: UInt64?, t2: UInt64?, t3: UInt64?, t4: UInt64?
 public init(_ stage: String, time: UInt64 = MonotonicClock.now, generation: UInt64 = 0,
             attachment: UUID? = nil, link: UUID? = nil, stream: UInt8? = nil, frame: UInt64? = nil,
             item: UInt64? = nil, sample: UInt64? = nil, start: UInt64? = nil, end: UInt64? = nil,
             depth: Int? = nil, bytes: Int? = nil, count: Int? = nil, code: String? = nil,
             t1: UInt64? = nil, t2: UInt64? = nil, t3: UInt64? = nil, t4: UInt64? = nil) {
  self.stage = stage; self.time = time; self.generation = generation; self.attachment = attachment
  self.link = link; self.stream = stream; self.frame = frame; self.item = item; self.sample = sample
  self.start = start; self.end = end; self.depth = depth; self.bytes = bytes; self.count = count; self.code = code
  self.t1 = t1; self.t2 = t2; self.t3 = t3; self.t4 = t4
 }
}
public struct PerformanceReport: Codable {
 public let clockBasis: String, mode: String
 public let capacity: Int, overwritten: UInt64, contentionDrops: UInt64
 public let events: [PerformanceEvent]
}

/// Producer never waits for the ring/export lock. Export can lose observations, never input.
/// Counter lock protects only one integer, never copies or encodes data.
public final class PerformanceRecorder {
 public static var optedIn: Bool {
  #if DEBUG
  return ProcessInfo.processInfo.environment["PADINK_PERF"] == "1"
  #else
  return false
  #endif
 }
 public let enabled: Bool
 private let lock = NSLock(), dropLock = NSLock(), capacity: Int
 private var ring: [PerformanceEvent?], cursor = 0, count = 0, overwritten: UInt64 = 0, drops: UInt64 = 0
 public init(enabled: Bool = PerformanceRecorder.optedIn, capacity: Int = 131072) {
  #if DEBUG
  self.enabled = enabled
  #else
  self.enabled = false
  #endif
  self.capacity = max(1, capacity); ring = self.enabled ? Array(repeating: nil, count: max(1, capacity)) : []
 }
 /// Autoclosure keeps disabled instrumentation from constructing events or reading clocks.
 public func record(_ event: @autoclosure () -> PerformanceEvent) {
  guard enabled else { return }
  let value = event()
  if PerformanceExperiment.videoLongRun, !PerformanceExperiment.retainsForVideoRun(value) { return }
  guard lock.try() else { dropLock.lock(); drops &+= 1; dropLock.unlock(); return }
  if count == capacity { overwritten &+= 1 }
  ring[cursor] = value; cursor = (cursor + 1) % capacity; count = min(capacity, count + 1)
  lock.unlock()
 }
 public func report(mode: String = PerformanceExperiment.mode.rawValue) -> PerformanceReport? {
  guard enabled else { return nil }
  lock.lock()
  let events = (0..<count).compactMap { ring[(cursor - count + $0 + capacity) % capacity] }
  let lost = overwritten
  lock.unlock()
  dropLock.lock(); let dropped = drops; dropLock.unlock()
  return PerformanceReport(clockBasis: "localMonotonicNanoseconds", mode: mode, capacity: capacity,
                           overwritten: lost, contentionDrops: dropped, events: events)
 }
}

/// Launch-time experiments only; no wire extension or product UI. Arm after actual presentation.
/// A new attachment requires a fresh arm. Relaunch both ends between conditions.
public enum PerformanceExperiment {
 public enum Mode: String { case normal, noVideo = "no-video", noDecode = "no-decode", noRender = "no-render", lowVideo = "low-video" }
 public static let mode: Mode = {
  guard PerformanceRecorder.optedIn else { return .normal }
  return Mode(rawValue: ProcessInfo.processInfo.environment["PADINK_PERF_MODE"] ?? "normal") ?? .normal
 }()
 // Fixed 10-minute, filtered trace uses the existing bounded ring (no periodic hot-path export).
 public static let videoLongRun = PerformanceRecorder.optedIn && ProcessInfo.processInfo.environment["PADINK_PERF_VIDEO_LONG"] == "1"
 public static func retainsForVideoRun(_ event: PerformanceEvent) -> Bool {
  ["video.capture", "video.encoded", "video.decoded", "video.presented", "video.receiveToPresent", "video.decoderConfigure", "video.decodeRecoveryCause", "video.decodeRejected", "video.gopReset"].contains(event.stage)
   || event.stage.hasPrefix("experiment.") || event.stage.hasPrefix("route.")
   || (event.stage == "wire.send" && event.stream == ConnectionKind.video.rawValue)
 }
 public static let warmup: UInt64 = 5_000_000_000
}

/// One finite experiment per attachment. Timers run on the existing owner queue.
/// Export begins only after the measurement window, never during its hot path.
public final class PerformanceWindow {
 private var armed: InputContext?
 public private(set) var active = false
 public init() {}
 public func reset() { armed = nil; active = false }
 public func arm(_ context: InputContext, diagnostics: Diagnostics, queue: DispatchQueue,
                 isCurrent: @escaping () -> Bool, begin: @escaping () -> Void) {
  guard diagnostics.performance.enabled, armed != context else { return }
  armed = context; active = false
  diagnostics.performance.record(PerformanceEvent("experiment.warmup", generation: UInt64(context.generation), attachment: context.attachmentID, code: PerformanceExperiment.mode.rawValue))
  queue.asyncAfter(deadline: .now() + .nanoseconds(Int(PerformanceExperiment.warmup))) { [weak self] in
   guard let self, self.armed == context, isCurrent() else { return }
   self.active = true; begin()
   diagnostics.performance.record(PerformanceEvent("experiment.begin", generation: UInt64(context.generation), attachment: context.attachmentID, code: PerformanceExperiment.mode.rawValue))
   queue.asyncAfter(deadline: .now() + .seconds(PerformanceExperiment.videoLongRun ? 600 : 45)) { [weak self] in
    guard let self, self.armed == context, isCurrent() else { return }
    diagnostics.performance.record(PerformanceEvent("experiment.end", generation: UInt64(context.generation), attachment: context.attachmentID, code: PerformanceExperiment.mode.rawValue))
    DispatchQueue.global(qos: .utility).async {
     let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("\(ProductIdentity.displayName) Performance", isDirectory: true)
     do { _ = try diagnostics.export(to: directory) }
     catch { diagnostics.fault(row: "8", reason: "performanceExportFailed", generation: context.generation) }
    }
   }
  }
 }
}
