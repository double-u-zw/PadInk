#if os(macOS)
import VideoToolbox
import PadInkCore
/// The same native configuration is exercised by the hardware loopback test.
public enum EncoderSettings {
 public static func bitrate(width:Int,height:Int)->Int {max(24_000_000,min(80_000_000,width*height*8))}
 public static func applyProfile(_ encoder: VTCompressionSession, width: Int, height: Int, profile: VideoProfile, settings: VideoSettings = .baseline) throws {
  let rate = settings.targetBitrate(baseline: bitrate(width: width, height: height), profile: profile)
  let values: [CFString: Any] = [kVTCompressionPropertyKey_AverageBitRate: rate,
   kVTCompressionPropertyKey_DataRateLimits: [rate / 8 * 2, 1],
   kVTCompressionPropertyKey_ExpectedFrameRate: profile.framesPerSecond,
   kVTCompressionPropertyKey_MaxKeyFrameInterval: profile.keyframeInterval]
  for (key, value) in values { let status = VTSessionSetProperty(encoder, key: key, value: value as CFTypeRef); guard status == noErr else { throw VideoPipelineError.codec(status) } }
 }
 public static func apply(_ encoder:VTCompressionSession,width:Int,height:Int, codec: VideoCodec = .h264)throws {
  let rate=bitrate(width:width,height:height)
  let properties:[CFString:Any]=[
   kVTCompressionPropertyKey_RealTime:true,
   kVTCompressionPropertyKey_AllowFrameReordering:false,
   kVTCompressionPropertyKey_ExpectedFrameRate:60,
   kVTCompressionPropertyKey_MaxKeyFrameInterval:60,
   kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration:1,
   kVTCompressionPropertyKey_ProfileLevel:codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
   kVTCompressionPropertyKey_AverageBitRate:rate,
   kVTCompressionPropertyKey_DataRateLimits:[rate/8*2,1],
   kVTCompressionPropertyKey_ColorPrimaries:kCVImageBufferColorPrimaries_ITU_R_709_2,
   kVTCompressionPropertyKey_TransferFunction:kCVImageBufferTransferFunction_ITU_R_709_2,
   kVTCompressionPropertyKey_YCbCrMatrix:kCVImageBufferYCbCrMatrix_ITU_R_709_2
  ]
  for (key,value) in properties {let status=VTSessionSetProperty(encoder,key:key,value:value as CFTypeRef);guard status==noErr else{throw VideoPipelineError.codec(status)}}
  var hardware:Unmanaged<CFTypeRef>?
  let copied=VTSessionCopyProperty(encoder,key:kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,allocator:nil,valueOut:&hardware)
  guard copied==noErr,(hardware?.takeRetainedValue() as? NSNumber)?.boolValue==true else{throw VideoPipelineError.hardware}
 }
}
#endif
