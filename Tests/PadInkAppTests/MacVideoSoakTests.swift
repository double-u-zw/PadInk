#if os(macOS)
import XCTest
import AppKit
import Darwin
import PadInkCore
@testable import PadInkMacKit

/// Explicit resource experiment, excluded from normal runs. It measures this XCTest process's
/// SCK/encode path only: no iPad, USB transport, decoder, renderer or input is involved.
final class MacVideoSoakTests: XCTestCase {
 private struct Sample: Codable {
  var label: String, elapsedMs: Double, userCpuMs: Double, systemCpuMs: Double
  var intervalCpuPercent: Double?, residentBytes: UInt64, physicalFootprintBytes: UInt64
  var captureFrames: UInt64, encodedFrames: UInt64, rawOverwrites: UInt64, queuedWakeSubmissions: UInt64
 }
 private struct Report: Codable {
  var condition: String, processID: Int32, system: String, rasterWidth: Int, rasterHeight: Int
  var rawSlotCapacity: Int = 1, pendingWakeCapacity: Int = 1
  var queueCapacityNote = "capacities are implementation bounds, not sampled high-water measurements"
  var cpuTimeSource = "proc_pid_rusage Mach absolute ticks converted using mach_timebase_info; CPU of this XCTest process only"
  var firstFrameMs: Double? = nil
  var releasedInstances: Int, expectedInstances: Int, errors: Int
  var samples: [Sample], firstFrameLatenciesMs: [Double]
 }
 private final class Observer: @unchecked Sendable {
  private let lock = NSLock(); private var first = false
  private(set) var errors = 0
  func frame(_ firstFrame: DispatchSemaphore) { lock.lock(); let fulfill = !first; first = true; lock.unlock(); if fulfill { firstFrame.signal() } }
  func error() { lock.lock(); errors += 1; lock.unlock() }
  var errorCount: Int { lock.lock(); defer { lock.unlock() }; return errors }
 }
 private func enabled() throws {
  guard ProcessInfo.processInfo.environment["PADINK_TEST_VIDEO_SOAK"] == "1" else { throw XCTSkip("three-minute SCK resource experiment not requested") }
  guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("test runner screen-recording permission is unavailable") }
 }
 private func sample(_ label: String, began: UInt64, previous: Sample?, diagnostics: Diagnostics) throws -> Sample {
  var usage = rusage_info_v4()
  let status = withUnsafeMutablePointer(to: &usage) {
   $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
  }
  guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
  let elapsed = Double(MonotonicClock.now - began) / 1e6
  var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
  let millisecondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e6
  let user = Double(usage.ri_user_time) * millisecondsPerTick, system = Double(usage.ri_system_time) * millisecondsPerTick
  let cpu = previous.flatMap { old in elapsed > old.elapsedMs ? 100 * ((user + system) - (old.userCpuMs + old.systemCpuMs)) / (elapsed - old.elapsedMs) : nil }
  let counters = diagnostics.report().counters
  return Sample(label: label, elapsedMs: elapsed, userCpuMs: user, systemCpuMs: system, intervalCpuPercent: cpu,
    residentBytes: usage.ri_resident_size, physicalFootprintBytes: usage.ri_phys_footprint,
    captureFrames: counters["video.capture"] ?? 0, encodedFrames: counters["video.encoded"] ?? 0,
    rawOverwrites: counters["video.rawOverwrite"] ?? 0, queuedWakeSubmissions: counters["video.captureWake"] ?? 0)
 }
 private func write(_ report: Report, suffix: String) throws {
  guard let base = ProcessInfo.processInfo.environment["PADINK_VIDEO_SOAK_REPORT"] else { return }
  let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(report).write(to: URL(fileURLWithPath: base + suffix + ".json"), options: .atomic)
 }
 private func drain(_ video: MacVideo) { video.queue.sync {}; video.queue.sync {} }
 func testRealScreenCaptureIdleThreeMinuteResourceSoakWhenExplicitlyEnabled() throws {
  try enabled()
  try runMacVideoExperiment(timeout: 220) { [self] state in try await idleSoak(state) }
 }
 private func idleSoak(_ state: MacVideoTestExperiment) async throws {
  let diagnostics = Diagnostics(), observer = Observer(), began = MonotonicClock.now
  var video: MacVideo? = MacVideo(session: 1, diagnostics: diagnostics, displayID: CGMainDisplayID())
  weak var retired = video
  state.track(video); defer { state.stopActive() }
  var report = Report(condition: "180 seconds; real main-display SCK plus hardware H.264, default 60fps profile, drawable 2732x2048; no intentional screen animation or input; host UI can still change; XCTest-process CPU/RSS/footprint only; no transport/iPad", processID: getpid(), system: ProcessInfo.processInfo.operatingSystemVersionString,
    rasterWidth: 0, rasterHeight: 0, releasedInstances: 0, expectedInstances: 1, errors: 0, samples: [], firstFrameLatenciesMs: [])
  report.samples.append(try sample("beforeStart", began: began, previous: nil, diagnostics: diagnostics))
  let first = DispatchSemaphore(value: 0)
  video!.onFrame = { _, _ in observer.frame(first) }; video!.onError = { _ in observer.error() }
  try await video!.start(drawable: CGSize(width: 2732, height: 2048))
  try Task.checkCancellation()
  guard first.wait(timeout: .now() + 10) == .success else { throw NSError(domain: "PadInkVideoFirstFrameTimeout", code: 1) }
  report.firstFrameMs = Double(MonotonicClock.now - began) / 1e6
  report.rasterWidth = Int(video!.raster.width); report.rasterHeight = Int(video!.raster.height)
  report.samples.append(try sample("captureStart", began: began, previous: report.samples.last, diagnostics: diagnostics))
  try write(report, suffix: "-idle")
  for index in 1...6 {
   try await Task.sleep(nanoseconds: 30_000_000_000)
   report.samples.append(try sample("capture\(index * 30)s", began: began, previous: report.samples.last, diagnostics: diagnostics))
   report.errors = observer.errorCount; try write(report, suffix: "-idle")
  }
  video!.stop(); drain(video!); video = nil
  for _ in 0..<100 where retired != nil { try await Task.sleep(nanoseconds: 10_000_000) }
  XCTAssertNil(retired)
  report.releasedInstances = retired == nil ? 1 : 0
  try await Task.sleep(nanoseconds: 5_000_000_000)
  report.samples.append(try sample("fiveSecondsAfterStop", began: began, previous: report.samples.last, diagnostics: diagnostics))
  report.errors = observer.errorCount; XCTAssertEqual(report.errors, 0)
  try write(report, suffix: "-idle")
  for value in report.samples { print("MacVideo 180s real SCK/encode resource sample: \(value)") }
 }
 func testRepeatedRealScreenCaptureFirstFrameStopResourcesWhenExplicitlyEnabled() throws {
  try enabled()
  try runMacVideoExperiment(timeout: 90) { [self] state in try await repeatedSoak(state) }
 }
 private func repeatedSoak(_ state: MacVideoTestExperiment) async throws {
  let began = MonotonicClock.now, diagnostics = Diagnostics()
  var report = Report(condition: "30 real main-display SCK start -> first hardware-encoded frame -> stop cycles; drawable 2732x2048; each instance weak-release checked; process resources include normal framework caches", processID: getpid(), system: ProcessInfo.processInfo.operatingSystemVersionString,
    rasterWidth: 0, rasterHeight: 0, releasedInstances: 0, expectedInstances: 30, errors: 0, samples: [], firstFrameLatenciesMs: [])
  report.samples.append(try sample("beforeCycles", began: began, previous: nil, diagnostics: diagnostics))
  for session in 1...30 {
   try Task.checkCancellation()
   let started = MonotonicClock.now, observer = Observer()
   var video: MacVideo? = MacVideo(session: UInt64(session), diagnostics: diagnostics, displayID: CGMainDisplayID())
   weak var retired = video
   state.track(video); defer { state.stopActive() }
   let first = DispatchSemaphore(value: 0)
   video!.onFrame = { _, _ in observer.frame(first) }; video!.onError = { _ in observer.error() }
   try await video!.start(drawable: CGSize(width: 2732, height: 2048))
   try Task.checkCancellation()
   guard first.wait(timeout: .now() + 10) == .success else { throw NSError(domain: "PadInkVideoFirstFrameTimeout", code: 1) }
   report.firstFrameLatenciesMs.append(Double(MonotonicClock.now - started) / 1e6)
   report.rasterWidth = Int(video!.raster.width); report.rasterHeight = Int(video!.raster.height)
   video!.stop(); drain(video!); video = nil
   for _ in 0..<100 where retired != nil { try await Task.sleep(nanoseconds: 10_000_000) }
   XCTAssertNil(retired, "real SCK cycle \(session) retained")
   if retired == nil { report.releasedInstances += 1 }
   report.errors += observer.errorCount
   if session % 5 == 0 {
    report.samples.append(try sample("after\(session)Cycles", began: began, previous: report.samples.last, diagnostics: diagnostics))
    try write(report, suffix: "-cycles")
   }
  }
  try await Task.sleep(nanoseconds: 5_000_000_000)
  report.samples.append(try sample("fiveSecondsAfterCycles", began: began, previous: report.samples.last, diagnostics: diagnostics))
  XCTAssertEqual(report.errors, 0); XCTAssertEqual(report.releasedInstances, report.expectedInstances)
  try write(report, suffix: "-cycles")
  print("MacVideo repeated real SCK resources: \(report.releasedInstances)/\(report.expectedInstances) released; firstFrameMs=\(report.firstFrameLatenciesMs); samples=\(report.samples)")
 }
}
#endif
