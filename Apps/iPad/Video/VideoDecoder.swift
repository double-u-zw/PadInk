import VideoToolbox
import PadInkCore

public enum DecodeError: Error, Equatable { case codec(Int32), hardware, value, staleGeneration }
public struct DecodedFrame {public let buffer:CVPixelBuffer;public let frame:VideoFrame;public let received:UInt64}
private final class DecodeContext {let frame:VideoFrame;let received:UInt64;let started=MonotonicClock.now;init(_ frame:VideoFrame,_ received:UInt64){self.frame=frame;self.received=received}}
/// Hardware H.264 decode, one compressed frame at a time on the media worker. DecodeGate
/// rejects stale generations and gapped P frames; VideoDecodePump bounds admission before
/// this worker, and the presentation permit fences retired epochs and expired pictures.
public final class VideoDecoder {
 public let latest=Latest<DecodedFrame>()
 private var decoder:VTDecompressionSession?,format:CMFormatDescription?,gate=DecodeGate(),config:VideoConfig?
 private let diagnostics:Diagnostics,session:UInt64
 public var codec: VideoCodec { config?.codec ?? .h264 }
 public var onDecodedConfig: ((VideoConfig) -> Void)?
 public var onRecovery:((UInt32, UInt64)->Void)?
 public var onFirstFrame:(()->Void)?
 private var hasFrame=false
 private var decodeFailed=false
 public init(session:UInt64,diagnostics:Diagnostics){self.session=session;self.diagnostics=diagnostics}
 public func configure(_ c:VideoConfig)throws {
  let configureStarted = MonotonicClock.now
  defer {
   let ended = MonotonicClock.now
   diagnostics.performance.record(PerformanceEvent("video.decoderConfigure", time: ended, generation: session, item: UInt64(c.generation), start: configureStarted, end: ended))
  }
  if let old=config,decoder != nil {
   guard c.generation>=old.generation else{throw DecodeError.staleGeneration}
   if c.generation==old.generation {guard c==old else{throw DecodeError.value};return}
  }
  reset();config=c
  var desc:CMFormatDescription?
  let result=c.sps.withUnsafeBytes{a in c.pps.withUnsafeBytes{b in c.vps.withUnsafeBytes{v in
   var pointers=[a.bindMemory(to:UInt8.self).baseAddress!,b.bindMemory(to:UInt8.self).baseAddress!];var sizes=[c.sps.count,c.pps.count]
   if c.codec == .hevc {
    guard let vp = v.bindMemory(to: UInt8.self).baseAddress, !c.vps.isEmpty else { return OSStatus(-50) }
    pointers.insert(vp, at: 0); sizes.insert(c.vps.count, at: 0)
    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator:kCFAllocatorDefault,parameterSetCount:3,parameterSetPointers:&pointers,parameterSetSizes:&sizes,nalUnitHeaderLength:4,extensions:nil,formatDescriptionOut:&desc)
   }
   return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:kCFAllocatorDefault,parameterSetCount:2,parameterSetPointers:&pointers,parameterSetSizes:&sizes,nalUnitHeaderLength:4,formatDescriptionOut:&desc)
  }}}
  guard result==noErr,let desc else{throw DecodeError.codec(result)}
  let dimensions=CMVideoFormatDescriptionGetDimensions(desc);guard dimensions.width==Int32(c.width),dimensions.height==Int32(c.height) else{throw DecodeError.value}
  format=desc
  let spec=[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:true] as CFDictionary
  let attrs=[kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary
  let s=VTDecompressionSessionCreate(allocator:kCFAllocatorDefault,formatDescription:desc,decoderSpecification:spec,imageBufferAttributes:attrs,outputCallback:nil,decompressionSessionOut:&decoder)
  guard s==noErr,let decoder else{throw DecodeError.codec(s)}
  var hardware:Unmanaged<CFTypeRef>?;VTSessionCopyProperty(decoder,key:kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,allocator:nil,valueOut:&hardware)
  guard (hardware?.takeRetainedValue() as? NSNumber)?.boolValue==true else{throw DecodeError.hardware}
  VTSessionSetProperty(decoder,key:kVTDecompressionPropertyKey_RealTime,value:kCFBooleanTrue)
  diagnostics.updateVideo { $0.codec = c.codec; $0.encodedWidth = Int(c.width); $0.encodedHeight = Int(c.height); $0.hardwareDecoder = true }
  gate.configure(c.generation)
 }
 /// Called on the dedicated media worker. `received` is before the worker hop, not decode start.
 public func decode(_ f:VideoFrame,received:UInt64=MonotonicClock.now,shouldPresent:@escaping ()->Bool={true})throws {
  diagnostics.mark("video.received",session:session,item:f.id,sourceTime:f.captureTime,value:Double(f.avcc.count))
  guard gate.accept(f),let decoder,let format else{
   diagnostics.performance.record(PerformanceEvent("video.decodeRejected", generation: session, item: f.id, code: "gate"))
   if shouldPresent() { onRecovery?(f.generation, f.id) };return
  }
  var block:CMBlockBuffer?
  let a=CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault,memoryBlock:nil,blockLength:f.avcc.count,blockAllocator:kCFAllocatorDefault,customBlockSource:nil,offsetToData:0,dataLength:f.avcc.count,flags:0,blockBufferOut:&block)
  guard a==noErr,let block else{throw DecodeError.codec(a)}
  let copied=f.avcc.withUnsafeBytes{CMBlockBufferReplaceDataBytes(with:$0.baseAddress!,blockBuffer:block,offsetIntoDestination:0,dataLength:f.avcc.count)}
  guard copied==noErr else{throw DecodeError.codec(copied)}
  var sample:CMSampleBuffer?;var size=f.avcc.count;var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:60),presentationTimeStamp:CMTime(value:Int64(f.id),timescale:60),decodeTimeStamp:.invalid)
  let b=CMSampleBufferCreateReady(allocator:kCFAllocatorDefault,dataBuffer:block,formatDescription:format,sampleCount:1,sampleTimingEntryCount:1,sampleTimingArray:&timing,sampleSizeEntryCount:1,sampleSizeArray:&size,sampleBufferOut:&sample)
  guard b==noErr,let sample else{throw DecodeError.codec(b)}
  let ctx=DecodeContext(f,received);decodeFailed=false
  let s=VTDecompressionSessionDecodeFrame(decoder,sampleBuffer:sample,flags:[],infoFlagsOut:nil){[weak self] status,flags,buffer,_,_ in
   guard let self else{return}
   guard status==noErr,!flags.contains(.frameDropped),let buffer else{self.decodeFailed=true;return}
   self.diagnostics.mark("video.decoded",session:self.session,item:f.id,sourceTime:f.captureTime,value:Double(MonotonicClock.now-ctx.started)/1e6)
   #if DEBUG
   VideoReferenceCapture.save(buffer, frame: f.id, session: self.session, role: "decoded")
   #endif
   guard shouldPresent() else{return}
   if self.latest.put(DecodedFrame(buffer:buffer,frame:f,received:received)){self.diagnostics.mark("video.decodedOverwrite",session:self.session,item:f.id)}
   self.diagnostics.updateVideo { $0.decodedPixelFormat = CVPixelBufferGetPixelFormatType(buffer); $0.decodedFrames += 1 }
   if !self.hasFrame{self.hasFrame=true; if let config = self.config { self.onDecodedConfig?(config) }; self.onFirstFrame?()}
  }
  VTDecompressionSessionWaitForAsynchronousFrames(decoder)
  if s != noErr || decodeFailed {
   diagnostics.performance.record(PerformanceEvent("video.decodeRejected", generation: session, item: f.id, code: "codec_\(s)_\(decodeFailed)"))
   gate.configure(f.generation);if shouldPresent() { onRecovery?(f.generation, f.id) }
  }
 }
 public func reset(){if let decoder{VTDecompressionSessionWaitForAsynchronousFrames(decoder);VTDecompressionSessionInvalidate(decoder)};decoder=nil;format=nil;config=nil;hasFrame=false;gate.reset();latest.clear()}
 deinit{reset()}
}
