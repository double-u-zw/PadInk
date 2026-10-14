import XCTest
import AppKit
import VideoToolbox
import PadInkCore
@testable import PadInkMacKit
@testable import PadInkPadKit

// Ported from Baseline v0.1.0 Tests/PadInkAppTests/AppTests.swift under the original names.
// TabletInputBackend is now PencilInjectionBackend. Dropped with their modules (ARCHITECTURE §10.2,
// §14 I-10): testActualSampleTimingSurvivesBatchPosting (ClockSync-calibrated event times),
// DeliverySchedulerTests (4, validation-only 60/120 Hz), DiagnosticExchangeTests (2, old exporter).
// All events go to in-memory sinks; nothing is posted to the system.

final class BackendTests: XCTestCase {
 func sample(_ seq: UInt64, _ phase: PencilPhase, x: Float = 0.5) -> PencilSample { PencilSample(stroke: 1, sequence: seq, timestamp: 100 * seq, x: x, y: 0.25, pressure: 0.75, altitude: 0.9, azimuth: 0.6, phase: phase) }
 func testRealCGEventFieldsAndTerminalEndpoint() throws {
  var events = [CGEvent](); let backend = PencilInjectionBackend(diagnostics: Diagnostics(), postEvent: { events.append($0) })
  backend.displayBounds = CGRect(x: 100, y: 50, width: 1000, height: 500); backend.reset(session: 7)
  try backend.begin([sample(1, .begin)], session: 7); try backend.samples([sample(2, .move)], session: 7); try backend.end([sample(3, .end, x: 0.9)], session: 7)
  XCTAssertEqual(events.map(\.type), [.tabletProximity, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .tabletProximity])
  XCTAssertEqual(events[0].getIntegerValueField(.tabletProximityEventEnterProximity), 1)
  XCTAssertEqual(events[1].getIntegerValueField(.mouseEventSubtype), 1)
  XCTAssertTrue(events[1].flags.contains(.maskNonCoalesced))
  XCTAssertTrue(events[2].flags.contains(.maskNonCoalesced))
  XCTAssertEqual(events[1].getDoubleValueField(.tabletEventPointPressure), 0.75, accuracy: 0.0001)
  XCTAssertEqual(events[1].getIntegerValueField(.tabletEventPointButtons), 1)
  XCTAssertEqual(events[1].getIntegerValueField(.tabletEventDeviceID), events[0].getIntegerValueField(.tabletProximityEventDeviceID))
  XCTAssertEqual(events[1].getIntegerValueField(.mouseEventNumber), events[3].getIntegerValueField(.mouseEventNumber))
  XCTAssertEqual(events[3].location.x, 1000, accuracy: 0.01)
  XCTAssertEqual(events[3].getDoubleValueField(.tabletEventPointPressure), 0)
  XCTAssertEqual(events[3].getIntegerValueField(.tabletEventPointButtons), 0)
  XCTAssertEqual(events[3].getIntegerValueField(.tabletEventPointZ), 0x50490003)
  XCTAssertEqual(events[1].getDoubleValueField(.tabletEventTiltX), sample(1,.begin).tilt.0, accuracy: 0.0001)
  XCTAssertEqual(events[1].getDoubleValueField(.tabletEventTiltY), sample(1,.begin).tilt.1, accuracy: 0.0001)
  XCTAssertEqual(events[4].getIntegerValueField(.tabletProximityEventEnterProximity), 0)
 }
 func testTerminalBridgeDistinguishesCancelAndResetFromLift() throws {
  for reset in [false,true] {
   var events=[CGEvent]();let backend=PencilInjectionBackend(diagnostics:Diagnostics(),postEvent:{events.append($0)})
   backend.reset(session:7);try backend.begin([sample(1,.begin)],session:7)
   if reset {backend.reset()} else{try backend.cancel([sample(2,.cancel)],session:7)}
   let up=events.first{$0.type == .leftMouseUp}!
   XCTAssertEqual(up.getIntegerValueField(.tabletEventPointZ),0x50490004)
  }
 }
 func testProximityIsAnchoredToActualContactNotAmbientMouseCursor() throws {
  var events = [CGEvent](); let b = PencilInjectionBackend(diagnostics: Diagnostics(), postEvent: { events.append($0) })
  b.displayBounds = CGRect(x: -1470, y: 100, width: 1470, height: 956); b.reset(session: 8)
  try b.begin([sample(1, .begin, x: 0.25)], session: 8); try b.end([sample(2, .end, x: 0.75)], session: 8)
  XCTAssertEqual(events[0].location, events[1].location)
  XCTAssertEqual(events[3].location, events[2].location)
  b.reset(session: 9); try b.begin([sample(1, .begin, x: 0.125)], session: 9); b.reset()
  XCTAssertEqual(events[events.count - 1].location, events[events.count - 2].location)
  XCTAssertEqual(events[events.count - 1].location.x, -1286.25, accuracy: 0.0001)
 }
 func testUncalibratedBatchKeepsSampleIntervalsAndResetUsesCurrentTime() throws {
  var events = [CGEvent](); let b = PencilInjectionBackend(diagnostics: Diagnostics(), postEvent: { events.append($0) })
  b.reset(session: 7)
  var points = [sample(1, .begin), sample(2, .move), sample(3, .move)]
  for n in points.indices { points[n].timestamp = UInt64(n) * 4_000_000 }
  try b.begin(points, session: 7)
  let native = events.filter { $0.type != .tabletProximity }
  XCTAssertEqual(native[1].timestamp - native[0].timestamp, 4_000_000)
  XCTAssertEqual(native[2].timestamp - native[1].timestamp, 4_000_000)
  let beforeReset = MonotonicClock.now; b.reset()
  let up = try XCTUnwrap(events.first(where: { $0.type == .leftMouseUp }))
  XCTAssertGreaterThanOrEqual(up.timestamp, beforeReset)
  XCTAssertGreaterThanOrEqual(up.timestamp, native.last!.timestamp)
 }
 func testDisconnectPostsSafeUpOnlyOnce() throws {
  var types = [CGEventType](); let b = PencilInjectionBackend(diagnostics: Diagnostics(), postEvent: { types.append($0.type) }); b.reset(session: 1); try b.begin([sample(1, .begin)], session: 1); b.reset(); b.reset()
  XCTAssertEqual(types, [.tabletProximity, .leftMouseDown, .leftMouseUp, .tabletProximity])
  XCTAssertThrowsError(try b.samples([sample(2, .move)], session: 1)); XCTAssertEqual(types.count, 4)
 }
 func testMalformedBatchNeverPostsPartialEvents() throws {
  var count = 0; let b = PencilInjectionBackend(diagnostics: Diagnostics(), postEvent: { _ in count += 1 }); b.reset(session: 1)
  XCTAssertThrowsError(try b.begin([sample(1, .begin), sample(3, .end)], session: 1)); XCTAssertEqual(count, 0)
 }
 /// 0.3: the product source state is Baseline's; the alternative exists only for the replay A/B.
 func testProductEventSourceStateIsBaselineHIDSystemState() {
  XCTAssertEqual(PencilInjectionBackend.productSourceState, .hidSystemState)
  XCTAssertEqual(PencilInjectionBackend(diagnostics: Diagnostics(), postEvent: { _ in }).sourceState, .hidSystemState)
  XCTAssertEqual(PencilInjectionBackend(diagnostics: Diagnostics(), sourceState: .privateState, postEvent: { _ in }).sourceState, .privateState)
 }
}

private final class EncodedSamples {
 let lock = NSLock(); var samples = [CMSampleBuffer](); var errors = [OSStatus]()
 func append(_ sample: CMSampleBuffer?, _ status: OSStatus) { lock.lock(); defer { lock.unlock() }; if let sample { samples.append(sample) }; if status != noErr { errors.append(status) } }
}
final class HardwareCodecTests: XCTestCase {
 func testHardwareH264NV12RoundTripAndReset() throws {
  let sink = EncodedSamples(); var encoder: VTCompressionSession?
  let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
  let created = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 640, height: 360, codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { ref, _, status, _, sample in Unmanaged<EncodedSamples>.fromOpaque(ref!).takeUnretainedValue().append(sample, status) }, refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &encoder)
  XCTAssertEqual(created, noErr); let e = try XCTUnwrap(encoder); defer { VTCompressionSessionInvalidate(e) }
  try EncoderSettings.apply(e, width: 640, height: 360)
  XCTAssertEqual(VTSessionSetProperty(e, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), noErr)
  var pixel: CVPixelBuffer?; XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
  let buffer = try XCTUnwrap(pixel); CVPixelBufferLockBaseAddress(buffer, [])
  for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? 100 : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) }; CVPixelBufferUnlockBaseAddress(buffer, [])
  for n in 0..<3 { XCTAssertEqual(VTCompressionSessionEncodeFrame(e, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(n), timescale: 60), duration: CMTime(value: 1, timescale: 60), frameProperties: n == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr) }
  VTCompressionSessionCompleteFrames(e, untilPresentationTimeStamp: .invalid)
  XCTAssertTrue(sink.errors.isEmpty); XCTAssertEqual(sink.samples.count, 3)
  let first = try XCTUnwrap(sink.samples.first), format = try XCTUnwrap(CMSampleBufferGetFormatDescription(first)); var sets = [Data]()
  for index in 0...1 { var p: UnsafePointer<UInt8>?, size = 0, count = 0; var nal: Int32 = 0; XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nal), noErr); sets.append(Data(bytes: try XCTUnwrap(p), count: size)) }
  let decoder = VideoDecoder(session: 1, diagnostics: Diagnostics()); try decoder.configure(VideoConfig(generation: 1, width: 640, height: 360, sps: sets[0], pps: sets[1]))
  for (index, sample) in sink.samples.enumerated() {
   let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample)); var data = Data(count: CMBlockBufferGetDataLength(block)); let size = data.count
   let result = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }; XCTAssertEqual(result, noErr)
   // Through the PINK/2 payload, exactly as the wire carries it.
   let frame = VideoFrame(generation: 1, id: UInt64(index + 1), captureTime: 1, key: index == 0, avcc: data)
   try decoder.decode(VideoFrame(payload: frame.encode(), keyframe: index == 0))
  }
  let decoded = try XCTUnwrap(decoder.latest.take()); XCTAssertEqual(CVPixelBufferGetWidth(decoded.buffer), 640); XCTAssertEqual(CVPixelBufferGetPixelFormatType(decoded.buffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange); XCTAssertEqual(decoded.frame.id, 3)
  decoder.reset(); XCTAssertNil(decoder.latest.take())
 }
 func testMetalPipelineCompiles() throws { let renderer = try MetalRenderer(diagnostics: Diagnostics()); XCTAssertFalse(renderer.device.name.isEmpty) }
}

final class CaptureRegionTests: XCTestCase {
 func testIndependentKnownVideoPointsReachQuartzCaptureRegion() throws {
  let geometry = VideoGeometry(source: CGSize(width: 2360, height: 1534), bounds: CGRect(x: 0, y: 0, width: 1180, height: 820))
  let cases: [(CGPoint, CGPoint)] = [(CGPoint(x: 0, y: 26.5), CGPoint(x: -1470, y: 100)), (CGPoint(x: 590, y: 410), CGPoint(x: -735, y: 578)), (CGPoint(x: 295, y: 218.25), CGPoint(x: -1102.5, y: 339)), (CGPoint(x: 885, y: 601.75), CGPoint(x: -367.5, y: 817))]
  for (view, expected) in cases {
   let normalized = try XCTUnwrap(geometry.normalized(view)); var received: CGEvent?
   let backend = PencilInjectionBackend(diagnostics: Diagnostics(), postEvent: { if $0.type == .leftMouseDown { received = $0 } })
   backend.displayBounds = CGRect(x: -1470, y: 100, width: 1470, height: 956); backend.reset(session: 1)
   try backend.begin([PencilSample(stroke: 1, sequence: 1, timestamp: 1, x: Float(normalized.x), y: Float(normalized.y), pressure: 0.5, altitude: 1, azimuth: 0, phase: .begin, geometryGeneration: 2)], session: 1)
   let event = try XCTUnwrap(received); XCTAssertEqual(event.location.x, expected.x, accuracy: 0.0001); XCTAssertEqual(event.location.y, expected.y, accuracy: 0.0001)
  }
 }
}
