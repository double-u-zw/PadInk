import Foundation

/// A bounded checkpoint, not a crash report. An unfinished marker can also result from force
/// quit, OS termination, power loss or an interrupted write; system crash reports remain primary.
public struct RecoveredSessionDiagnostics: Codable {
 public let runID: UUID, startedAt: Date, checkpointAt: Date
 public let video: VideoRuntime?
 public let session: SessionDiagnostics?, metrics: DiagnosticMetrics?
 public let counters: [String: UInt64], faults: [FaultRecord], traces: [Trace], actions: [InputActionRecord]
 init(runID: UUID, startedAt: Date, report: DiagnosticReport) {
  let safe = report.supportSafe()
  self.runID = runID; self.startedAt = startedAt; checkpointAt = safe.generatedAt
  video = safe.video
  session = safe.session; metrics = safe.metrics; counters = safe.counters
  faults = Array((safe.faults ?? []).suffix(128)); traces = Array(safe.traces.suffix(128)); actions = Array((safe.actions ?? []).suffix(128))
 }
 func supportSafe() -> RecoveredSessionDiagnostics {
  var report = DiagnosticReport(formatVersion: 3, generatedAt: checkpointAt, capacity: traces.count, totalRecords: 0,
   counters: counters, traces: traces, session: session, metrics: metrics, faults: faults)
  report.video = video
  report.actions = actions
  return RecoveredSessionDiagnostics(runID: runID, startedAt: startedAt, report: report)
 }
}

/// Confined to the caller's persistence queue. A single atomic file retains this run and at most
/// one prior unfinished run. Failure to persist must never stop the product session.
public final class DiagnosticRecoveryStore {
 private struct Record: Codable {
  var endedNormally: Bool
  var current: RecoveredSessionDiagnostics
  var previousUnfinished: RecoveredSessionDiagnostics?
 }
 public static let maximumFileBytes = 512 * 1024
 private let file: URL
 private var record: Record?
 public init(directory: URL) { file = directory.appendingPathComponent("last-session.json") }
 public var previousUnfinishedSession: RecoveredSessionDiagnostics? { record?.previousUnfinished }
 @discardableResult public func begin(report: DiagnosticReport) throws -> RecoveredSessionDiagnostics? {
  let old: Record? = {
   guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
         let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFileBytes,
         let data = try? Data(contentsOf: file) else { return nil }
   return try? JSONDecoder().decode(Record.self, from: data)
  }()
  let previous = old.flatMap { $0.endedNormally ? nil : $0.current.supportSafe() }
  let retained = previous ?? old?.previousUnfinished?.supportSafe()
  record = Record(endedNormally: false, current: RecoveredSessionDiagnostics(runID: UUID(), startedAt: report.generatedAt, report: report), previousUnfinished: retained)
  try save()
  return previous
 }
 public func checkpoint(report: DiagnosticReport, endedNormally: Bool = false) throws {
  guard var current = record else { return }
  current.current = RecoveredSessionDiagnostics(runID: current.current.runID, startedAt: current.current.startedAt, report: report)
  current.endedNormally = endedNormally; record = current; try save()
 }
 private func save() throws {
  guard let record else { return }
  let data = try JSONEncoder().encode(record)
  guard data.count <= Self.maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
  try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: file, options: .atomic)
 }
}
