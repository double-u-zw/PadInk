#if os(macOS)
import XCTest
import VideoToolbox
import PadInkCore
@testable import PadInkPadKit
import PadInkMacKit

private final class RecoveryEncodedSamples {
 let lock = NSLock(); var samples: [CMSampleBuffer] = [], errors: [OSStatus] = []
 func append(_ sample: CMSampleBuffer?, _ status: OSStatus) { lock.lock(); defer { lock.unlock() }; if let sample { samples.append(sample) }; if status != noErr { errors.append(status) } }
}
final class VideoDecodeRecoveryTests: XCTestCase {
 func testRendererReplacementClearsOldDecodedSlotAndEpoch() throws {
  let renderer = try MetalRenderer(diagnostics: Diagnostics()), old = Latest<DecodedFrame>(), fresh = Latest<DecodedFrame>()
  let oldEpoch = UUID(), freshEpoch = UUID(), input = InputContext(attachmentID: UUID(), generation: 1)
  renderer.inputContext = input; renderer.replaceVideoSource(old, epoch: oldEpoch)
  var pixel: CVPixelBuffer?
  XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
  let f = VideoFrame(generation: 1, id: 1, captureTime: 1, key: true, avcc: Data([1]))
  old.put(DecodedFrame(buffer: try XCTUnwrap(pixel), frame: f, received: 1))
  renderer.replaceVideoSource(fresh, epoch: freshEpoch)
  XCTAssertNil(old.take()); XCTAssertTrue(renderer.latest === fresh); XCTAssertEqual(renderer.videoEpoch, freshEpoch)
  XCTAssertEqual(renderer.inputContext, input, "B-only recovery must not end input ownership")
  renderer.clear(); XCTAssertNil(renderer.videoEpoch)
 }
 /// Actual hardware H.264, not a mock decoded picture: overload loses a dependency chain;
 /// retaining SPS/PPS plus a new IDR must produce a presentable frame again.
 func testHardwareDecodeAfterPredecodeOverflowAndEpochReplacement() throws {
  let sink = RecoveryEncodedSamples(); var encoder: VTCompressionSession?
  let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
  let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 640, height: 360, codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
   outputCallback: { ref, _, status, _, sample in Unmanaged<RecoveryEncodedSamples>.fromOpaque(ref!).takeUnretainedValue().append(sample, status) },
   refcon: Unmanaged.passUnretained(sink).toOpaque(), compressionSessionOut: &encoder)
  XCTAssertEqual(result, noErr); let e = try XCTUnwrap(encoder); defer { VTCompressionSessionInvalidate(e) }
  try EncoderSettings.apply(e, width: 640, height: 360)
  XCTAssertEqual(VTSessionSetProperty(e, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse), noErr)
  var pixel: CVPixelBuffer?
  XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
  let buffer = try XCTUnwrap(pixel); CVPixelBufferLockBaseAddress(buffer, [])
  for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? 100 : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) }
  CVPixelBufferUnlockBaseAddress(buffer, [])
  for n in 0..<8 {
   let options = n == 0 || n == 6 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
   XCTAssertEqual(VTCompressionSessionEncodeFrame(e, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(n), timescale: 60), duration: CMTime(value: 1, timescale: 60), frameProperties: options, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
  }
  VTCompressionSessionCompleteFrames(e, untilPresentationTimeStamp: .invalid)
  XCTAssertTrue(sink.errors.isEmpty); XCTAssertEqual(sink.samples.count, 8)
  var wire: [Frame] = [], sets: [Data] = []
  for (index, sample) in sink.samples.enumerated() {
   let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample)); var data = Data(count: CMBlockBufferGetDataLength(block)); let count = data.count
   XCTAssertEqual(data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }, noErr)
   let key = index == 0 || index == 6, generation: UInt32 = index >= 6 ? 2 : 1
   if key {
    let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample)); sets.removeAll()
    for n in 0...1 { var p: UnsafePointer<UInt8>?, size = 0, parameters = 0; var nal: Int32 = 0
     XCTAssertEqual(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: n, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &parameters, nalUnitHeaderLengthOut: &nal), noErr)
     sets.append(Data(bytes: try XCTUnwrap(p), count: size))
    }
    let config = VideoConfig(generation: generation, width: 640, height: 360, sps: sets[0], pps: sets[1])
    wire.append(Frame(type: .videoConfig, generation: 1, sequence: 1, timestamp: 1, payload: config.encode()))
   }
   let frame = VideoFrame(generation: generation, id: UInt64(index + 1), captureTime: 1, key: key, avcc: data)
   wire.append(Frame(type: .videoFrame, flags: key ? [.critical, .keyframe] : [.critical], generation: 1, sequence: 1, timestamp: 1, payload: frame.encode()))
  }
  let input = InputContext(attachmentID: UUID(), generation: 1), old = VideoDecodeContext(attachment: input), fresh = VideoDecodeContext(attachment: input)
  var jobs: [() -> Void] = [], requests = 0, firstFrames = 0, errors: [Error] = []
  let pump = VideoDecodePump(maxFrameAge: 5_000_000_000, schedule: { jobs.append($0) }), decoder = VideoDecoder(session: 1, diagnostics: Diagnostics())
  decoder.onFirstFrame = { firstFrames += 1 }; decoder.onRecovery = { pump.invalidate(old, generation: $0, frameID: $1) }
  let consume: VideoDecodePump.Consume = { f, received, permit in
   do { if f.type == .videoConfig { try decoder.configure(VideoConfig(f.payload)) }
    else { try decoder.decode(VideoFrame(payload: f.payload, keyframe: f.flags.contains(.keyframe)), received: received, shouldPresent: permit) }
   } catch { errors.append(error) }
  }
  pump.activate(old, consume: consume, reset: { decoder.reset() }, recovery: { requests += 1 })
  // Configuration and six pictures arrive while the worker is stopped.
  for f in wire.prefix(7) { pump.push(f, context: old, received: MonotonicClock.now) }
  XCTAssertTrue(pump.snapshot.waitingForIDR); XCTAssertEqual(requests, 1); XCTAssertEqual(pump.snapshot.peakPendingFrames, 2)
  // A source recovery supplies an independent IDR and its following P picture.
  for f in wire.suffix(3) { pump.push(f, context: old, received: MonotonicClock.now) }
  jobs.removeFirst()()
  XCTAssertTrue(errors.isEmpty); XCTAssertEqual(decoder.latest.take()?.frame.id, 8); XCTAssertEqual(firstFrames, 1)
  pump.activate(fresh, consume: { _, _, _ in }, reset: {}, recovery: {})
  XCTAssertFalse(pump.push(wire.last!, context: old, received: MonotonicClock.now))
  jobs.removeFirst()(); XCTAssertNil(decoder.latest.take()); XCTAssertEqual(pump.snapshot.scheduledWorkers, 0)
  pump.deactivate(); jobs.removeFirst()()
 }
}
#endif
