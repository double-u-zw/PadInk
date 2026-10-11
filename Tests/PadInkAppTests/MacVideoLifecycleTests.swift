#if os(macOS)
import XCTest
import AppKit
import VideoToolbox
import PadInkCore
import PadInkPadKit
@testable import PadInkMacKit

/// A synchronous XCTest entry avoids AppKit's main-executor integration affecting async XCTest
/// dispatch. Detached work has a hard outer timeout; stop closes callbacks even if an SDK await
/// does not cooperate with Task cancellation. Never use this helper for product scheduling.
final class MacVideoTestExperiment: @unchecked Sendable {
 private let lock = NSLock()
 private weak var video: MacVideo?
 private var cancelled = false, failure: Error?
 func track(_ value: MacVideo?) { lock.lock(); video = value; let stop = cancelled; lock.unlock(); if stop { value?.stop() } }
 func stopActive() { lock.lock(); let active = video; video = nil; lock.unlock(); active?.stop() }
 func cancel() { lock.lock(); cancelled = true; lock.unlock(); stopActive() }
 func finish(_ error: Error?) { lock.lock(); failure = error; lock.unlock() }
 var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
}
extension XCTestCase {
 func runMacVideoExperiment(timeout: TimeInterval, operation: @escaping @Sendable (MacVideoTestExperiment) async throws -> Void) throws {
  let finished = expectation(description: "detached video experiment completed"), state = MacVideoTestExperiment()
  let task = Task.detached {
   defer { state.stopActive(); finished.fulfill() }
   do { try await operation(state); state.finish(nil) } catch { state.finish(error) }
  }
  let result = XCTWaiter.wait(for: [finished], timeout: timeout)
  guard result == .completed else {
   state.cancel(); task.cancel()
   throw NSError(domain: "PadInkVideoTestTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey: "SCK experiment exceeded \(timeout)s; active capture stopped and callbacks cleared"])
  }
  if let error = state.error { throw error }
 }
}

/// Exercises actual MacVideo callback wiring, raw admission and the hardware encoder. SCK capture
/// is opt-in because test runners have a separate screen-recording permission from the signed app.
final class MacVideoLifecycleTests: XCTestCase {
 private func buffer(width: Int = 640, height: Int = 360) throws -> CVPixelBuffer {
  var pixel: CVPixelBuffer?
  XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
  let value = try XCTUnwrap(pixel)
  CVPixelBufferLockBaseAddress(value, [])
  for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(value, plane), plane == 0 ? 100 : 128,
    CVPixelBufferGetBytesPerRowOfPlane(value, plane) * CVPixelBufferGetHeightOfPlane(value, plane)) }
  CVPixelBufferUnlockBaseAddress(value, [])
  return value
 }
 private func selfCapturingOutputs(_ video: MacVideo) {
  video.onFrame = { [video] _, _ in _ = video.session }
  video.onError = { [video] _ in _ = video.session }
  video.shouldSkip = { [video] in video.session == 0 }
 }
 private func drain(_ video: MacVideo) {
  // CompleteFrames may queue finished behind the first barrier while stop is executing.
  video.queue.sync {}; video.queue.sync {}
 }
 func testStopBreaksStoredOutputCyclesAndIsIdempotent() {
  for session in 1...100 {
   var video: MacVideo? = MacVideo(session: UInt64(session), diagnostics: Diagnostics(capacity: 64), displayID: CGMainDisplayID())
   weak var retired = video
   selfCapturingOutputs(video!)
   video!.stop(); video!.stop(); drain(video!)
   XCTAssertNil(video!.onFrame); XCTAssertNil(video!.onError)
   video = nil
   XCTAssertNil(retired, "stopped capture \(session) retained its output callbacks")
  }
 }
 func testCoordinatorStoredAndQueuedCallbacksDoNotOwnVideo() {
  let queue = DispatchQueue(label: "test.video.owner")
  let blocked = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
  queue.async { entered.signal(); blocked.wait() }
  XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
  var video: MacVideo? = MacVideo(session: 1, diagnostics: Diagnostics(), displayID: CGMainDisplayID())
  weak var retired = video
  var frames = 0, errors = 0
  MacCoordinator.connectVideo(video!, queue: queue, isCurrent: { _ in true },
    onFrame: { _, _ in frames += 1 }, onError: { _ in errors += 1 })
  video!.onFrame?(nil, VideoFrame(generation: 1, id: 1, captureTime: 1, key: true, avcc: Data()))
  video!.onError?(VideoPipelineError.capture)
  video = nil
  XCTAssertNil(retired, "stored or queued callbacks retain the capture")
  blocked.signal(); queue.sync {}
  XCTAssertEqual(frames, 0); XCTAssertEqual(errors, 0)
 }
 func testQueuedFrameAndErrorRecheckReplacementBeforeExecution() {
  let queue = DispatchQueue(label: "test.video.replacement")
  let blocked = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
  queue.async { entered.signal(); blocked.wait() }
  XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
  let old = MacVideo(session: 1, diagnostics: Diagnostics(), displayID: CGMainDisplayID())
  let fresh = MacVideo(session: 2, diagnostics: Diagnostics(), displayID: CGMainDisplayID())
  var current: MacVideo? = old, frames = 0, errors = 0
  MacCoordinator.connectVideo(old, queue: queue, isCurrent: { current === $0 },
    onFrame: { _, _ in frames += 1 }, onError: { _ in errors += 1 })
  old.onFrame?(nil, VideoFrame(generation: 1, id: 1, captureTime: 1, key: true, avcc: Data()))
  old.onError?(VideoPipelineError.capture)
  current = fresh
  blocked.signal(); queue.sync {}
  XCTAssertEqual(frames, 0); XCTAssertEqual(errors, 0)
  old.stop(); fresh.stop(); drain(old); drain(fresh)
 }
 func testStoppedCaptureRejectsLateBuffersAndErrors() throws {
  let video = MacVideo(session: 1, diagnostics: Diagnostics(), displayID: CGMainDisplayID())
  let pixel = try buffer(); var errors = 0
  video.onError = { _ in errors += 1 }
  video.stop()
  for n in 0..<10_000 { XCTAssertFalse(video.acceptRaw(pixel, time: UInt64(n))) }
  video.reportError(VideoPipelineError.capture)
  drain(video)
  XCTAssertEqual(errors, 0)
 }
 func testStalledEncodeQueueKeepsOneCaptureWakeAndNewestRaw() throws {
  let diagnostics = Diagnostics(capacity: 128)
  let video = MacVideo(session: 1, diagnostics: diagnostics, displayID: CGMainDisplayID())
  let pixel = try buffer()
  try video.prepareEncoder(raster: CGSize(width: 640, height: 360))
  let blocked = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
  video.queue.async { entered.signal(); blocked.wait() }
  XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
  for n in 1...10_000 { XCTAssertTrue(video.acceptRaw(pixel, time: UInt64(n))) }
  XCTAssertEqual(diagnostics.report().counters["video.captureWake"], 1)
  XCTAssertEqual(diagnostics.report().counters["video.rawOverwrite"], 9_999)
  let encoded = expectation(description: "latest raw encoded after stall")
  var resumedAt: UInt64 = 0, recoveryNs: UInt64 = 0
  video.onFrame = { _, frame in XCTAssertEqual(frame.captureTime, 10_000); recoveryNs = MonotonicClock.now - resumedAt; encoded.fulfill() }
  resumedAt = MonotonicClock.now; blocked.signal()
  wait(for: [encoded], timeout: 5)
  video.stop(); drain(video)
  XCTAssertEqual(diagnostics.report().counters["video.acceptedEncode"], 1)
  print("MacVideo stalled encode queue: 10000 raw arrivals, 1 queued wake, 1 newest frame encoded; recoveryMs=\(Double(recoveryNs) / 1e6)")
 }
 func testHardwareEncoderRepeatedPrepareCaptureStopReleasesEveryInstance() throws {
  let pixel = try buffer(), start = MonotonicClock.now
  for session in 1...20 {
   var video: MacVideo? = MacVideo(session: UInt64(session), diagnostics: Diagnostics(capacity: 64), displayID: CGMainDisplayID())
   weak var retired = video
   try video!.prepareEncoder(raster: CGSize(width: 640, height: 360))
   selfCapturingOutputs(video!)
   XCTAssertTrue(video!.acceptRaw(pixel, time: UInt64(session)))
   video!.requestKeyframe(); video!.setProfile(VideoProfile()); video!.backlogCleared()
   video!.stop(); drain(video!); video = nil
   XCTAssertNil(retired, "hardware capture \(session) survives stop")
  }
  print("MacVideo hardware prepare/feed/stop: 20/20 instances released; elapsedMs=\(Double(MonotonicClock.now - start) / 1e6)")
 }
 func testStoppedInstanceCannotCreateAnotherEncoder() throws {
  let video = MacVideo(session: 1, diagnostics: Diagnostics(), displayID: CGMainDisplayID())
  video.stop(); drain(video)
  XCTAssertThrowsError(try video.prepareEncoder(raster: CGSize(width: 640, height: 360)))
 }
 func testOverlappingHardwareFramesStayOrderedAcrossKeyframeRecoveryAndProfileChange() throws {
  for codec in VideoCodec.allCases { try overlappingHardwareFrames(codec: codec) }
 }
 private func overlappingHardwareFrames(codec: VideoCodec) throws {
  let diagnostics = Diagnostics(capacity: 4096, developerDetailed: true)
  let video = MacVideo(session: 1, diagnostics: diagnostics, displayID: CGMainDisplayID(), settings: .daily(.hd, codec: codec))
  let decoder = VideoDecoder(session: 1, diagnostics: diagnostics)
  let pixel = try buffer(width: 2940, height: 1912)
  try video.prepareEncoder(raster: CGSize(width: 2940, height: 1912))
  var frames: [VideoFrame] = [], configurations: [UInt32: UInt64] = [:], errors = 0
  video.onFrame = { config, frame in
   if let config { configurations[config.generation] = configurations[config.generation] ?? frame.id }
   frames.append(frame)
   do {
    if let config { try decoder.configure(config) }
    try decoder.decode(frame)
    XCTAssertNotNil(decoder.latest.take(), "\(codec) output must really decode after each transition")
   } catch { errors += 1 }
  }
  video.onError = { _ in errors += 1 }
  let start = MonotonicClock.now
  for n in 0..<80 {
   video.acceptRaw(pixel, time: start + UInt64(n) * 16_666_667)
   if n == 20 { video.requestKeyframe() }
   if n == 40 { video.setProfile(VideoProfile(.reducedBitrate)) }
   Thread.sleep(forTimeInterval: 1.0 / 60)
  }
  let drained = expectation(description: "hardware callbacks drained")
  video.queue.asyncAfter(deadline: .now() + 0.5) { drained.fulfill() }
  wait(for: [drained], timeout: 5)
  video.stop(); drain(video)
  XCTAssertEqual(errors, 0)
  XCTAssertGreaterThan(frames.count, 3)
  guard !frames.isEmpty else { return }
  XCTAssertEqual(frames.map(\.id), Array(1...UInt64(frames.count)))
  XCTAssertGreaterThanOrEqual(Set(frames.map(\.generation)).count, 3)
  for frame in frames {
   XCTAssertNotNil(configurations[frame.generation])
   if configurations[frame.generation] == frame.id { XCTAssertTrue(frame.key) }
  }
  let admissions = diagnostics.report().traces.filter { $0.stage == "video.acceptedEncode" }
  XCTAssertFalse(admissions.isEmpty)
  XCTAssertTrue(admissions.allSatisfy { (1...2).contains($0.value ?? 0) })
 }
 func testRealScreenCaptureRepeatedStartStopWhenExplicitlyEnabled() throws {
  try screenCaptureEnabled()
  try runMacVideoExperiment(timeout: 30) { [self] state in try await repeatedScreenCapture(state) }
 }
 private func screenCaptureEnabled() throws {
  guard ProcessInfo.processInfo.environment["PADINK_TEST_SCREEN_CAPTURE"] == "1" else {
   throw XCTSkip("real SCK capture not requested; hardware lifecycle tests still run")
  }
  guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("test runner screen-recording permission is unavailable") }
 }
 private func repeatedScreenCapture(_ state: MacVideoTestExperiment) async throws {
  var releaseMs: [Double] = []
  for session in 1...5 {
   try Task.checkCancellation()
   var video: MacVideo? = MacVideo(session: UInt64(session), diagnostics: Diagnostics(capacity: 64), displayID: CGMainDisplayID())
   weak var retired = video
   state.track(video); defer { state.stopActive() }
   let captured = DispatchSemaphore(value: 0)
   var received = false
   video!.onFrame = { _, _ in if !received { received = true; captured.signal() } }
   try await video!.start(drawable: CGSize(width: 640, height: 360))
   try Task.checkCancellation()
   guard captured.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "PadInkVideoFirstFrameTimeout", code: 1) }
   let stoppedAt = MonotonicClock.now
   video!.stop(); drain(video!); video = nil
   for _ in 0..<100 where retired != nil { try await Task.sleep(nanoseconds: 10_000_000) }
   XCTAssertNil(retired, "real SCK capture \(session) survives stop")
   releaseMs.append(Double(MonotonicClock.now - stoppedAt) / 1e6)
  }
  print("MacVideo real SCK start/stop: 5/5 instances released; releaseMs=\(releaseMs)")
 }
 func testRealScreenCaptureStopWhileStartingWhenExplicitlyEnabled() throws {
  try screenCaptureEnabled()
  try runMacVideoExperiment(timeout: 30) { [self] state in try await stoppedWhileStarting(state) }
 }
 private func stoppedWhileStarting(_ state: MacVideoTestExperiment) async throws {
  for session in 1...20 {
   try Task.checkCancellation()
   var video: MacVideo? = MacVideo(session: UInt64(session), diagnostics: Diagnostics(capacity: 64), displayID: CGMainDisplayID())
   weak var retired = video
   state.track(video); defer { state.stopActive() }
   let task = Task { [video = video!] in try await video.start(drawable: CGSize(width: 640, height: 360)) }
   try await Task.sleep(nanoseconds: 1_000_000)
   video!.stop()
   _ = try? await task.value
   try Task.checkCancellation()
   drain(video!); video = nil
   for _ in 0..<100 where retired != nil { try await Task.sleep(nanoseconds: 10_000_000) }
   XCTAssertNil(retired, "cancelled SCK startup \(session) survives its completed task")
  }
  print("MacVideo real SCK stop-during-start: 20/20 instances released after SDK task completion")
 }
}
#endif
