import Foundation
/// Bounded diagnostics ring and counters (Baseline). The Phase 2 structured local diagnostics
/// (REWRITE_BRIEF §13) build on this; the Baseline support summary was not ported.
public struct Trace: Codable {
 public var ordinal:UInt64=0
 public var stage: String, session: UInt64, item: UInt64, sequence: UInt64, time: UInt64
 public var sourceTime: UInt64?, x: Float?, y: Float?, pressure: Float?, phase: UInt8?, state: String?
 public var altitude:Float?,azimuth:Float?,flags:UInt8?
 public var value: Double?
 public var eventTime:UInt64?,screenX:Double?,screenY:Double?,eventFlags:UInt64?
 public var geometryGeneration:UInt32?,viewX:Double?,viewY:Double?,estimatedProperties:UInt64?,expectingUpdates:UInt64?,estimationIndex:Int64?,eventType:UInt32?
}
public final class Diagnostics {
 private let lock=NSLock()
 // Small copy-on-write blocks keep a retained snapshot from copying the whole
 // ring on the next Pencil write. Readers iterate after releasing the lock.
 private static let blockSize=128
 private var records: [[Trace?]]
 private var cursor=0, count=0
 private var total:UInt64=0
 private var counters=[String:UInt64]()
 private var videoRuntime = VideoRuntime()
 public func updateVideo(_ update: (inout VideoRuntime) -> Void) { lock.lock(); update(&videoRuntime); lock.unlock() }
 private var support = SessionDiagnostics(), faults: [FaultRecord] = []
 private let actionLock = NSLock(), actionDropLock = NSLock()
 private var actions: [InputActionRecord?] = Array(repeating: nil, count: Diagnostics.actionCapacity)
 private var actionCursor = 0, actionCount = 0
 private var actionTotal: UInt64 = 0, actionDrops: UInt64 = 0
 public static let actionCapacity = 4096
 public let performance: PerformanceRecorder
 public let capacity:Int
 private let detailedLocal: Bool
 private let recoveryQueue = DispatchQueue(label: "pnk2.diagnostics.persistence", qos: .utility)
 private var recoveryStore: DiagnosticRecoveryStore?, lastRecoveryCheckpoint: UInt64 = 0
 private var previousUnfinished: RecoveredSessionDiagnostics?
 public static var developerDetailedOptIn: Bool {
  #if DEBUG
  return ProcessInfo.processInfo.environment["PADINK_DETAILED_DIAGNOSTICS"] == "1"
  #else
  return false
  #endif
 }
 public init(capacity: Int=32768, developerDetailed: Bool = Diagnostics.developerDetailedOptIn, performance: PerformanceRecorder = PerformanceRecorder()) {
  self.performance = performance
  self.capacity=max(1,capacity);records=Array(repeating:Array(repeating:nil,count:Self.blockSize),count:(max(1,capacity)+Self.blockSize-1)/Self.blockSize)
  #if DEBUG
  detailedLocal = developerDetailed
  #else
  detailedLocal = false
  #endif
 }
 public func mark(_ stage:String,session:UInt64=0,item:UInt64=0,sequence:UInt64=0,time:UInt64=MonotonicClock.now,sourceTime:UInt64?=nil,sample:PencilSample?=nil,state:String?=nil,value:Double?=nil,eventTime:UInt64?=nil,screenX:Double?=nil,screenY:Double?=nil,eventFlags:UInt64?=nil,viewX:Double?=nil,viewY:Double?=nil,estimatedProperties:UInt64?=nil,expectingUpdates:UInt64?=nil,estimationIndex:Int64?=nil,eventType:UInt32?=nil,geometryGeneration:UInt32?=nil) {
  if performance.enabled, ["input.callbackRaw", "input.raw", "input.send", "input.post", "input.resetPost", "input.cancel", "input.rejected", "input.backendRejected", "video.capture", "video.acceptedEncode", "video.encoded", "video.decoded", "video.presented", "video.receiveToPresent", "video.rawOverwrite", "video.decodedOverwrite", "video.gopReset"].contains(stage) {
   // Numeric association only. Never bridge arbitrary state/value (which may contain pressure).
   performance.record(PerformanceEvent(stage, time: time, generation: session, item: sample?.stroke ?? item,
    sample: sample?.sequence ?? sequence, start: sample?.timestamp ?? sourceTime))
  }
  var t=Trace(stage:stage,session:session,item:sample?.stroke ?? item,sequence:sample?.sequence ?? sequence,time:time,sourceTime:sample?.timestamp ?? sourceTime,x:sample?.x,y:sample?.y,pressure:sample?.pressure,phase:sample?.phase,state:state ?? sample.map{PencilPhase(rawValue:$0.phase).map{String(describing:$0)} ?? "invalid"},altitude:sample?.altitude,azimuth:sample?.azimuth,flags:sample?.flags,value:value)
  t.eventTime=eventTime;t.screenX=screenX;t.screenY=screenY;t.eventFlags=eventFlags
  t.geometryGeneration=sample?.geometryGeneration ?? geometryGeneration;t.viewX=viewX;t.viewY=viewY;t.estimatedProperties=estimatedProperties;t.expectingUpdates=expectingUpdates;t.estimationIndex=estimationIndex;t.eventType=eventType
  if !detailedLocal { t = t.supportSafe() }
  lock.lock(); total+=1;t.ordinal=total;if counters[stage] != nil || counters.count<128{counters[stage,default:0]+=1}; records[cursor/Self.blockSize][cursor%Self.blockSize]=t; cursor=(cursor+1)%capacity; count=min(count+1,capacity);
  lock.unlock()
 }
 private struct Window {let records:[[Trace?]],cursor:Int,count:Int,total:UInt64,counters:[String:UInt64]}
 private func window()->Window {lock.lock();defer{lock.unlock()};return Window(records:records,cursor:cursor,count:count,total:total,counters:counters)}
 private func traces(_ window:Window,where include:(Trace)->Bool)->[Trace] {
  (0..<window.count).compactMap{offset in
   let index=(window.cursor-window.count+offset+capacity)%capacity
   guard let trace=window.records[index/Self.blockSize][index%Self.blockSize],include(trace) else{return nil}
   return trace
  }
 }
 public func snapshot(where include:(Trace)->Bool={_ in true}) -> [Trace] {traces(window(),where:include)}
 public func fps(_ stage:String,now:UInt64=MonotonicClock.now) -> Double {Double(snapshot{$0.stage==stage && $0.time<=now && now-$0.time<2_000_000_000}.count)/2}
 public func updateSession(_ value: SessionDiagnostics) { lock.lock(); support = value; lock.unlock() }
 /// Callers pass fixed reason codes only, never interpolated error text or application content.
 public func fault(row: String, reason: String, generation: UInt32, now: UInt64 = MonotonicClock.now) {
  let rows: Set<String> = ["1", "2", "3", "4", "5", "6", "7", "7b", "8"]
  guard rows.contains(row), !reason.isEmpty, reason.count <= 80,
        reason.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else { return }
  lock.lock(); faults.append(FaultRecord(time: now, generation: generation, row: row, reason: reason)); if faults.count > 256 { faults.removeFirst() }; lock.unlock()
 }
 /// Best-effort observation only. A busy export drops the record instead of waiting for its lock.
 /// Slots never escape this object, so writing/overwriting a slot does not copy a retained snapshot.
 public func action(_ stage: InputActionStage, context: InputContext?, kind: InputActionKind, gesture: UInt64, sequence: UInt32 = 0, geometryGeneration: UInt32? = nil, reason: InputActionReason? = nil, time: UInt64 = MonotonicClock.now) {
  guard actionLock.try() else { droppedAction(); return }
  actionTotal &+= 1
  if actionCount == Self.actionCapacity { droppedAction() }
  actions[actionCursor] = InputActionRecord(ordinal: actionTotal, time: time, stage: stage, attachmentID: context?.attachmentID, generation: context?.generation ?? 0, kind: kind, gesture: gesture, sequence: sequence, geometryGeneration: geometryGeneration, reason: reason)
  actionCursor = (actionCursor + 1) % Self.actionCapacity; actionCount = min(actionCount + 1, Self.actionCapacity)
  actionLock.unlock()
 }
 private func droppedAction() { actionDropLock.lock(); actionDrops &+= 1; actionDropLock.unlock() }
 public var droppedActionRecords: UInt64 { actionDropLock.lock(); defer { actionDropLock.unlock() }; return actionDrops }
 private func actionSnapshot() -> (records: [InputActionRecord], dropped: UInt64) {
  actionLock.lock()
  let result = (0..<actionCount).compactMap { actions[(actionCursor - actionCount + $0 + Self.actionCapacity) % Self.actionCapacity] }
  let dropped = droppedActionRecords
  actionLock.unlock()
  return (result, dropped)
 }
 public func actionJournal(where include: (InputActionRecord) -> Bool = { _ in true }) -> [InputActionRecord] { actionSnapshot().records.filter(include) }
 public func report(after:UInt64=0, includePerformance: Bool = true)->DiagnosticReport {
  let w=window()
  let all = traces(w) { _ in true }
  lock.lock(); let status = support, journal = faults, previous = previousUnfinished, video = videoRuntime; lock.unlock()
  let input = actionSnapshot()
  var r = DiagnosticReport(formatVersion:3,generatedAt:Date(),capacity:capacity,totalRecords:w.total,counters:w.counters,traces:all.filter { $0.ordinal > after }, session: status, metrics: DiagnosticMetrics(traces: all, now: MonotonicClock.now), faults: journal)
  r.video = video
  r.actions = input.records; r.droppedActionRecords = input.dropped; r.previousUnfinishedSession = previous
  r.detail = detailedLocal ? "developer-local-detailed" : "support"
  r.clockBasis = detailedLocal ? "localMonotonicNanoseconds" : "elapsedWithinReportNanoseconds"
  var result = detailedLocal ? r : r.supportSafe()
  result.performance = includePerformance ? performance.report() : nil
  return result
 }
 public func write(_ report:DiagnosticReport,to directory:URL)throws->URL {
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  let url=directory.appendingPathComponent("PadInk-\(ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-"))-\(UUID().uuidString).json")
  var output = detailedLocal ? report : report.supportSafe()
  // Only this explicitly enabled Debug instance may export raw performance clocks.
  output.performance = performance.enabled ? report.performance : nil
  try JSONEncoder().encode(output).write(to:url,options:.withoutOverwriting);return url
 }
 public func export(to directory:URL)throws->URL {try write(report(),to:directory)}
 public static var defaultRecoveryDirectory: URL {
  let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  return root.appendingPathComponent(Bundle.main.bundleIdentifier ?? "PadInk").appendingPathComponent("Diagnostics", isDirectory: true)
 }
 /// Called once during host startup before user interaction. Only a small support checkpoint is
 /// read/written; subsequent disk work occurs on the utility queue rather than the input queue.
 @discardableResult public func beginSessionRecovery(in directory: URL = Diagnostics.defaultRecoveryDirectory) throws -> Bool {
  try recoveryQueue.sync {
   let store = DiagnosticRecoveryStore(directory: directory)
   let previous = try store.begin(report: report(includePerformance: false).supportSafe())
   recoveryStore = store
   lock.lock(); previousUnfinished = store.previousUnfinishedSession; lock.unlock()
   return previous != nil
  }
 }
 public func checkpointSessionRecovery(force: Bool = false) {
  recoveryQueue.async { [weak self] in
   guard let self, let store = self.recoveryStore else { return }
   let now = MonotonicClock.now
   guard force || self.lastRecoveryCheckpoint == 0 || now &- self.lastRecoveryCheckpoint >= 5_000_000_000 else { return }
   self.lastRecoveryCheckpoint = now
   do { try store.checkpoint(report: self.report(includePerformance: false).supportSafe()) }
   catch { self.fault(row: "8", reason: "diagnosticCheckpointUnavailable", generation: 0) }
  }
 }
 public func finishSessionRecovery() {
  recoveryQueue.sync {
   do { try recoveryStore?.checkpoint(report: report(includePerformance: false).supportSafe(), endedNormally: true) }
   catch { fault(row: "8", reason: "diagnosticCheckpointUnavailable", generation: 0) }
   recoveryStore = nil // Late tick/background checkpoints must not reopen a normally ended run.
  }
 }

}
public struct Distribution: Codable {
 public var p50:Double,p95:Double,p99:Double,max:Double
 public var sampleCount:Int? // Optional when reading reports produced before format 3.
 public init(_ values:[Double]) {sampleCount=values.count;let v=values.sorted(); func p(_ q:Double)->Double {v.isEmpty ? 0:v[min(v.count-1,Int(Double(v.count-1)*q))]}; p50=p(0.5);p95=p(0.95);p99=p(0.99);max=v.last ?? 0}
}
public struct TimingStats {
 public static func intervals(_ records:[Trace],stage:String) -> Distribution {
  let v=records.filter{$0.stage==stage}.map(\.time).sorted()
  return Distribution(zip(v.dropFirst(),v).map{Double($0-$1)/1e6})
 }
}

public struct DiagnosticReport:Codable {public var video: VideoRuntime?; public var performance: PerformanceReport?;public var formatVersion:Int,generatedAt:Date,capacity:Int,totalRecords:UInt64,counters:[String:UInt64],traces:[Trace]; public var session: SessionDiagnostics?; public var metrics: DiagnosticMetrics?; public var faults: [FaultRecord]?; public var actions: [InputActionRecord]?; public var droppedActionRecords: UInt64?; public var detail: String?; public var clockBasis: String?; public var previousUnfinishedSession: RecoveredSessionDiagnostics?}
/// Fixed vocabulary and identity metadata only; no coordinates, pressure, titles or paths.
public enum InputActionStage: String, Codable { case capture, admission, drop, gestureState; case sendAdmitted = "send-admitted" }
public enum InputActionKind: String, Codable { case pencil, pointer, scroll, magnify, geometry, pencilGesture, touchGesture, keepalive }
public enum InputActionReason: String, Codable { case nilContext, noAttachment, identityMismatch, attachmentEnded, invalidPayload, connectionUnavailable, gestureCancelled, captureQueueExpired, captureQueueOverflow, sendQueueOverflow }
/// send-admitted means this endpoint queued bytes, never that the Mac application executed them.
public struct InputActionRecord: Codable, Equatable {
 public var ordinal: UInt64, time: UInt64, stage: InputActionStage, attachmentID: UUID?, generation: UInt32, kind: InputActionKind
 public var gesture: UInt64, sequence: UInt32, geometryGeneration: UInt32?, reason: InputActionReason?
}
