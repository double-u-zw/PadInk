#if os(macOS)
import ScreenCaptureKit
import VideoToolbox
import PadInkCore

public enum VideoPipelineError: Error, Equatable { case capture, codec(Int32), hardware, frameTooLarge }

private final class EncodeContext {
 let time: UInt64, id: UInt64, start: UInt64, generation: UInt32
 init(time: UInt64, id: UInt64, generation: UInt32) { self.time = time; self.id = id; self.generation = generation; start = MonotonicClock.now }
}

/// ScreenCaptureKit -> VideoToolbox H.264, ported from Baseline v0.1.0 (byte-identical in 0.2.0;
/// 30-minute soak B-001). Kept: only `.complete` frames and a latest-raw slot,
/// last raw buffer re-encoded as IDR on a static desktop, generation per forced IDR.
/// 0.3 change: `shouldSkip` is consulted before each encode (fault row 1, first rung). While it
/// returns true no new frame is encoded; the newest raw frame simply waits in the slot (latest wins),
/// so congestion never builds an encoded backlog. Forced IDRs are never skipped.
public final class MacVideo: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
 public let queue = DispatchQueue(label: "pnk2.encode", qos: .userInteractive)
 private let raw = Latest<(CVPixelBuffer, UInt64)>(), diagnostics: Diagnostics
 // SCK callbacks may arrive after stop and while the encode queue is occupied. Admit under one
 // lock and keep at most one wake queued; the raw slot remains latest-wins.
 private let captureLock = NSLock()
 private var captureOpen = true, captureWakeScheduled = false
 private var stream: SCStream?, encoder: VTCompressionSession?, stopped = false, forceIDR = true
 // Overlap capture/codec work without growing a latency queue. Completed callbacks still occupy
 // their slot until emitted in input order, so even an out-of-order callback cannot grow storage.
 private var inFlight = 0, emittedID: UInt64 = 0
 private var completed: [UInt64: (EncodeContext, OSStatus, CMSampleBuffer?)] = [:]
 private var id: UInt64 = 0, width = 0, height = 0
 private var generation: UInt32 = 0
 public let settings: VideoSettings
 private let extended: Bool
 public var targetBitrate: Int { queue.sync { currentTargetBitrate } }
 private var currentTargetBitrate: Int { settings.targetBitrate(baseline: EncoderSettings.bitrate(width: width, height: height), profile: appliedProfile) }
 private var desiredProfile = VideoProfile(), appliedProfile = VideoProfile(), lastEncodeTime: UInt64 = 0, frameDelayScheduled = false
 private var capturedGeometryRecorded = false
 private var lastRaw: (CVPixelBuffer, UInt64)?
 public let session: UInt64
 public let displayID: CGDirectDisplayID
 public var raster: CGSize { CGSize(width: width, height: height) }
 public var onFrame: ((VideoConfig?, VideoFrame) -> Void)?, onError: ((Error) -> Void)?
 /// Read on the encode queue; must be cheap and thread-safe.
 public var shouldSkip: () -> Bool = { false }
 public init(session: UInt64, diagnostics: Diagnostics, displayID: CGDirectDisplayID, settings: VideoSettings = .baseline, extended: Bool = false, generationSeed: UInt32 = 0) { self.settings = settings; self.extended = extended; self.generation = generationSeed; self.session = session; self.diagnostics = diagnostics; self.displayID = displayID }
 public func start(drawable: CGSize) async throws {
  guard queue.sync(execute: { !stopped }) else { throw VideoPipelineError.capture }
  let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw VideoPipelineError.capture }
  let mode = CGDisplayCopyDisplayMode(display.displayID)
  let source = CGSize(width: mode?.pixelWidth ?? CGDisplayPixelsWide(display.displayID), height: mode?.pixelHeight ?? CGDisplayPixelsHigh(display.displayID))
  diagnostics.mark("video.sourceRaster", session: session, state: "\(Int(source.width))x\(Int(source.height))", value: Double(display.displayID))
  diagnostics.mark("video.negotiatedDrawable", session: session, state: "\(Int(drawable.width))x\(Int(drawable.height))")
  diagnostics.updateVideo { $0.sourceWidth = Int(source.width); $0.sourceHeight = Int(source.height); $0.drawableWidth = Int(drawable.width); $0.drawableHeight = Int(drawable.height) }
  try prepareEncoder(raster: VideoGeometry.raster(source: source, drawable: drawable, resolution: settings.resolution, extended: extended))
  let config = SCStreamConfiguration(); config.width = width; config.height = height; config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  if settings.resolution != .current { config.captureResolution = .best }
  config.colorSpaceName = CGColorSpace.sRGB; config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2; config.minimumFrameInterval = CMTime(value: 1, timescale: 60); config.queueDepth = 3; config.showsCursor = true; config.capturesAudio = false
  let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
  try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "pnk2.capture", qos: .userInteractive)); try queue.sync { guard !stopped else { throw VideoPipelineError.capture }; stream = s }
  try await s.startCapture()
  if queue.sync(execute: { stopped }) { try? await s.stopCapture(); throw VideoPipelineError.capture }
 }
 /// The production encoder setup is also exercised without SCK/TCC by lifecycle tests.
 func prepareEncoder(raster: CGSize) throws {
  try queue.sync {
   guard !stopped, encoder == nil else { throw VideoPipelineError.capture }
   width = Int(raster.width); height = Int(raster.height)
   try makeEncoder()
  }
 }
 private func makeEncoder() throws {
  let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
  let result = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: settings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: { ref, context, status, _, sample in
   guard let ref, let context else { return }
   let owner = Unmanaged<MacVideo>.fromOpaque(ref).takeUnretainedValue(), frame = Unmanaged<EncodeContext>.fromOpaque(context).takeRetainedValue()
   owner.queue.async { owner.finished(frame, status: status, sample: sample) }
  }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &encoder)
  guard result == noErr, let encoder else { throw VideoPipelineError.codec(result) }
  try EncoderSettings.apply(encoder, width: width, height: height, codec: settings.codec)
  try EncoderSettings.applyProfile(encoder, width: width, height: height, profile: desiredProfile, settings: settings)
  appliedProfile = desiredProfile
  let ready = VTCompressionSessionPrepareToEncodeFrames(encoder); guard ready == noErr else { throw VideoPipelineError.codec(ready) }
  diagnostics.updateVideo { $0.encodedWidth = width; $0.encodedHeight = height; $0.codec = settings.codec; $0.targetBitrate = currentTargetBitrate; $0.hardwareEncoder = true }
  diagnostics.mark("video.raster", session: session, state: "\(width)x\(height) \(settings.codec) hardware", value: Double(currentTargetBitrate))
 }
 public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
  guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
  if !capturedGeometryRecorded { capturedGeometryRecorded = true; let info = attachments[0]
   diagnostics.updateVideo {
    $0.captureMatrix709 = (CVBufferCopyAttachment(buffer,kCVImageBufferYCbCrMatrixKey,nil) as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    $0.captureTransferSRGB = (CVBufferCopyAttachment(buffer,kCVImageBufferTransferFunctionKey,nil) as? String) == (kCVImageBufferTransferFunction_sRGB as String)
    $0.captureTransfer709 = (CVBufferCopyAttachment(buffer,kCVImageBufferTransferFunctionKey,nil) as? String) == (kCVImageBufferTransferFunction_ITU_R_709_2 as String)
    $0.captureScaleFactor = (info[.scaleFactor] as? NSNumber)?.doubleValue
    $0.captureContentScale = (info[.contentScale] as? NSNumber)?.doubleValue
   }
   diagnostics.mark("video.captureGeometry", session: session, state: "contentRect=\(String(describing: info[.contentRect])); contentScale=\(String(describing: info[.contentScale])); scaleFactor=\(String(describing: info[.scaleFactor])); buffer=\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))") }
  diagnostics.updateVideo { $0.captureWidth = CVPixelBufferGetWidth(buffer); $0.captureHeight = CVPixelBufferGetHeight(buffer); $0.encodedPixelFormat = CVPixelBufferGetPixelFormatType(buffer) }
  _ = acceptRaw(buffer, time: MonotonicClock.now)
 }
 /// Returns false for a late capture callback after stop. No buffer or work is retained then.
 @discardableResult func acceptRaw(_ buffer: CVPixelBuffer, time: UInt64) -> Bool {
  captureLock.lock()
  guard captureOpen else { captureLock.unlock(); return false }
  let overwritten = raw.put((buffer, time)), wake = !captureWakeScheduled
  captureWakeScheduled = true
  captureLock.unlock()
  diagnostics.mark("video.capture", session: session, time: time)
  if overwritten { diagnostics.mark("video.rawOverwrite", session: session) }
  if wake {
   diagnostics.mark("video.captureWake", session: session)
   queue.async { [weak self] in
    guard let self else { return }
    let now = MonotonicClock.now
    self.diagnostics.performance.record(PerformanceEvent("video.encodeQueue", time: now, generation: self.session, start: time, end: now))
    self.captureLock.lock(); self.captureWakeScheduled = false; self.captureLock.unlock()
    self.encodeNext()
   }
  }
  return true
 }
 /// Applied between frames and followed by an IDR; geometry is unchanged while FPS/bitrate fall.
 public func setProfile(_ profile: VideoProfile) { queue.async { [weak self] in guard let self, !self.stopped else { return }; self.desiredProfile = profile; self.encodeNext() } }
 public func requestKeyframe() { queue.async { [weak self] in guard let self, !self.stopped else { return }; self.forceIDR = true; if let last = self.lastRaw { self.raw.putIfEmpty(last) }; self.encodeNext() } }
 /// Called when the sender's backlog clears, so a waiting raw frame is not stranded on a static desktop.
 public func backlogCleared() { queue.async { [weak self] in self?.encodeNext() } }
 private func encodeNext() {
  guard !stopped, inFlight < (appliedProfile.transport == .usb ? 2 : 1), let encoder else { return }
  // Drain the previous configuration before changing rate or creating a recovery generation.
  if inFlight > 0 && (forceIDR || appliedProfile != desiredProfile) { return }
  if appliedProfile != desiredProfile {
   do {
    try EncoderSettings.applyProfile(encoder, width: width, height: height, profile: desiredProfile, settings: settings)
    appliedProfile = desiredProfile; forceIDR = true
    diagnostics.updateVideo { $0.targetBitrate = currentTargetBitrate }
    diagnostics.mark("video.profile", session: session, state: appliedProfile.quality.rawValue, value: Double(currentTargetBitrate))
   } catch {
    diagnostics.fault(row: "1", reason: "profileApplyFailed", generation: UInt32(truncatingIfNeeded: session))
    desiredProfile = appliedProfile
   }
  }
  let now = MonotonicClock.now
  if !forceIDR, appliedProfile.quality == .reducedFrameRate, now >= lastEncodeTime {
   let interval = UInt64(1_000_000_000 / appliedProfile.framesPerSecond)
   if now - lastEncodeTime < interval {
    if !frameDelayScheduled {
     frameDelayScheduled = true
     queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: lastEncodeTime + interval)) { [weak self] in self?.frameDelayScheduled = false; self?.encodeNext() }
    }
    diagnostics.mark("video.fpsSkip", session: session); return
   }
  }
  if !forceIDR && shouldSkip() { diagnostics.mark("video.skipBeforeEncode", session: session); return }
  guard let (buffer, time) = raw.take() else { return }
  lastEncodeTime = now; lastRaw = (buffer, time); inFlight += 1; id += 1
  if forceIDR { generation += 1 }
  #if DEBUG
  VideoReferenceCapture.save(buffer, frame: id, session: session, role: "source")
  #endif
  let ctx = EncodeContext(time: time, id: id, generation: generation); let pointer = Unmanaged.passRetained(ctx).toOpaque()
  let options = forceIDR ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil; forceIDR = false
  diagnostics.mark("video.acceptedEncode", session: session, item: id, sourceTime: time, value: Double(inFlight))
  let s = VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(time), timescale: 1_000_000_000), duration: CMTime(value: 1, timescale: CMTimeScale(appliedProfile.framesPerSecond)), frameProperties: options, sourceFrameRefcon: pointer, infoFlagsOut: nil)
  if s != noErr { Unmanaged<EncodeContext>.fromOpaque(pointer).release(); finished(ctx, status: s, sample: nil) }
 }
 private func finished(_ context: EncodeContext, status: OSStatus, sample: CMSampleBuffer?) {
  guard !stopped else { return }
  completed[context.id] = (context, status, sample)
  while let result = completed.removeValue(forKey: emittedID + 1) {
   emittedID += 1; inFlight -= 1
   emit(result.0, status: result.1, sample: result.2)
  }
  encodeNext()
 }
 private func emit(_ context: EncodeContext, status: OSStatus, sample: CMSampleBuffer?) {
  guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { onError?(VideoPipelineError.codec(status)); return }
  let actualDimensions = CMVideoFormatDescriptionGetDimensions(format)
  guard CMFormatDescriptionGetMediaSubType(format) == (settings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264), actualDimensions.width == width, actualDimensions.height == height else { onError?(VideoPipelineError.capture); return }
  let length = CMBlockBufferGetDataLength(block); guard length <= (MessageRegistry.spec(.videoFrame)?.maxPayload ?? 0) - 20 else { onError?(VideoPipelineError.frameTooLarge); return }
  var bytes = Data(count: length); let copied = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
  guard copied == noErr else { onError?(VideoPipelineError.codec(copied)); return }
  let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
  let key = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  var config: VideoConfig?
  if key {
   var sets = [Data]()
   for index in 0..<(settings.codec == .hevc ? 3 : 2) { var p: UnsafePointer<UInt8>?, size = 0, count = 0; var nal: Int32 = 0
    let s = settings.codec == .hevc
     ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nal)
     : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nal)
    guard s == noErr, let p, size > 0, size < 65536, nal == 4 else { onError?(VideoPipelineError.codec(s)); return }; sets.append(Data(bytes: p, count: size))
   }; config = VideoConfig(generation: context.generation, width: UInt32(width), height: UInt32(height), sps: sets[settings.codec == .hevc ? 1 : 0], pps: sets[settings.codec == .hevc ? 2 : 1], codec: settings.codec, vps: settings.codec == .hevc ? sets[0] : Data())
  }
  diagnostics.mark("video.encoded", session: session, item: context.id, sourceTime: context.time, value: Double(MonotonicClock.now - context.start) / 1e6)
  onFrame?(config, VideoFrame(generation: context.generation, id: context.id, captureTime: context.time, key: key, avcc: bytes))
 }
 public func stream(_ stream: SCStream, didStopWithError error: Error) { reportError(error) }
 /// Serializes SDK/start errors with stop, so a retired capture cannot report a new failure.
 public func reportError(_ error: Error) {
  queue.async { [weak self] in guard let self, !self.stopped else { return }; self.onError?(error) }
 }
 func recordSendQueue(_ enqueued: UInt64, frame: UInt64) {
  let now = MonotonicClock.now
  diagnostics.performance.record(PerformanceEvent("video.sendQueue", time: now, generation: session, item: frame, start: enqueued, end: now))
 }
 public func stop() {
  // Close capture ingress immediately, before queued codec cleanup. SCK can deliver late frames.
  captureLock.lock()
  guard captureOpen else { captureLock.unlock(); return }
  captureOpen = false; raw.clear(); captureLock.unlock()
  queue.async {
   guard !self.stopped else { return }
   self.stopped = true; self.onFrame = nil; self.onError = nil; self.shouldSkip = { false }
   self.raw.clear(); self.lastRaw = nil; self.completed.removeAll(); self.inFlight = 0
   if let encoder = self.encoder { VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(encoder); self.encoder = nil }
   if let stream = self.stream {
    try? stream.removeStreamOutput(self, type: .screen)
    Task {
     do { try await stream.stopCapture(); self.diagnostics.performance.record(PerformanceEvent("video.captureStopped", generation: self.session)) }
     catch { self.diagnostics.performance.record(PerformanceEvent("video.captureStopFailed", generation: self.session)) }
    }
   }
   self.stream = nil
  }
 }
}
#endif
