#if os(macOS)
import XCTest
import AppKit
import CoreText
import VideoToolbox
import PadInkCore
@testable import PadInkMacKit
@testable import PadInkPadKit

/// Opt-in, deterministic same-frame comparison. Synthetic type/line/stroke/scroll patterns,
/// not evidence of real PDF/PPT/Goodnotes interaction or iPad transport performance.
final class VideoQualityExperimentTests: XCTestCase {
 private final class Sink: @unchecked Sendable {
  let ready = DispatchSemaphore(value: 0)
  var frame: VideoFrame?, config: VideoConfig?, error: Error?
 }
 private struct Result: Codable {
  var codec: String, width: Int, height: Int, targetMbps: Double, frames: Int
  var elapsed: Double, actualMbps: Double, peakSecondMbps: Double, loopbackFPS: Double
  var lumaPSNR: Double, edgePSNR: Double, encodeMs: Distribution?, decodeMs: Distribution?
  var error: String?
 }
 private func source(width: Int, height: Int, offset: Int) throws -> CVPixelBuffer {
  var pixel: CVPixelBuffer?
  XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
  let b = try XCTUnwrap(pixel)
  if let path = ProcessInfo.processInfo.environment["PADINK_VIDEO_REFERENCE_FILE"] {
   let data = try Data(contentsOf: URL(fileURLWithPath:path)), sw = 2940, sh = 1912
   guard data.count == sw*sh*3/2 else { throw VideoPipelineError.capture }
   var original: CVPixelBuffer?
   XCTAssertEqual(CVPixelBufferCreate(nil,sw,sh,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&original),kCVReturnSuccess)
   let source = try XCTUnwrap(original); CVPixelBufferLockBaseAddress(source,[])
   data.withUnsafeBytes { raw in
    for plane in 0..<2 {
     let rows = plane == 0 ? sh : sh/2, start = plane == 0 ? 0 : sw*sh
     let ptr = CVPixelBufferGetBaseAddressOfPlane(source,plane)!, stride = CVPixelBufferGetBytesPerRowOfPlane(source,plane)
     for y in 0..<rows { memcpy(ptr.advanced(by:y*stride),raw.baseAddress!.advanced(by:start+((y+offset/(plane+1))%rows)*sw),sw) }
    }
   }
   CVPixelBufferUnlockBaseAddress(source,[])
   var transfer: VTPixelTransferSession?; XCTAssertEqual(VTPixelTransferSessionCreate(allocator:nil,pixelTransferSessionOut:&transfer),noErr)
   let t = try XCTUnwrap(transfer); defer { VTPixelTransferSessionInvalidate(t) }
   XCTAssertEqual(VTPixelTransferSessionTransferImage(t,from:source,to:b),noErr)
   return b
  }
  CVPixelBufferLockBaseAddress(b, []); defer { CVPixelBufferUnlockBaseAddress(b, []) }
  let ptr = CVPixelBufferGetBaseAddressOfPlane(b, 0)!, stride = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
  memset(ptr, 235, stride * height)
  let context = try XCTUnwrap(CGContext(data: ptr, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
  context.setFillColor(gray: 16.0/255, alpha: 1)
  for row in 0..<(height / 28 + 4) {
   let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat([10,12,16,24][row % 4]), nil)
   let text = NSAttributedString(string: "PDF 0123456789 小字 / PPT AaBbCc — fine lines and handwriting", attributes: [.font: font, .foregroundColor: CGColor(gray: 16.0/255, alpha: 1)])
   context.textPosition = CGPoint(x: 24, y: row * 28 - offset)
   CTLineDraw(CTLineCreateWithAttributedString(text), context)
  }
  context.setStrokeColor(gray: 16.0/255, alpha: 1)
  for n in 0..<80 {
   context.setLineWidth(CGFloat(n % 3 + 1)); context.move(to: CGPoint(x: width/2+n*7, y: 20-offset))
   context.addCurve(to: CGPoint(x: width/2+n*7+120, y: height-20-offset), control1: CGPoint(x: width/2+n*7-100,y: height/3), control2: CGPoint(x: width/2+n*7+180,y: height*2/3));context.strokePath()
  }
  let chroma = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self), cs = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
  memset(chroma, 128, cs * height/2)
  for y in 0..<height/2 { for x in Swift.stride(from: width/2, to: width, by: 2) { chroma[y*cs+x] = UInt8(96 + (x/32+y/32+offset)%64); chroma[y*cs+x+1] = UInt8(96 + (x/64+y/16+offset)%64) } }
  CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
  return b
 }
 private func error(_ source: CVPixelBuffer, _ decoded: CVPixelBuffer) -> (Double, Double) {
  CVPixelBufferLockBaseAddress(source, .readOnly);CVPixelBufferLockBaseAddress(decoded, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(source,.readOnly); CVPixelBufferUnlockBaseAddress(decoded,.readOnly) }
  let w=CVPixelBufferGetWidth(source),h=CVPixelBufferGetHeight(source)
  let a=CVPixelBufferGetBaseAddressOfPlane(source,0)!.assumingMemoryBound(to:UInt8.self), b=CVPixelBufferGetBaseAddressOfPlane(decoded,0)!.assumingMemoryBound(to:UInt8.self)
  let sa=CVPixelBufferGetBytesPerRowOfPlane(source,0),sb=CVPixelBufferGetBytesPerRowOfPlane(decoded,0)
  var total=0.0,edges=0.0,count=0.0
  // Sampling every second row bounds measurement overhead and is identical in every condition.
  for y in stride(from:1,to:h-1,by:2) { for x in 1..<w-1 {
   let v=Int(a[y*sa+x]),d=Double(v-Int(b[y*sb+x])); total += d*d
   if abs(v-Int(a[y*sa+x-1])) > 8 || abs(v-Int(a[(y-1)*sa+x])) > 8 {edges += d*d;count += 1}
  }}
  return (total / Double(((h-1)/2)*(w-2)), edges / max(1,count))
 }
 func testSameFrameHardwareMatrixWhenRequested() throws {
  guard ProcessInfo.processInfo.environment["PADINK_VIDEO_MATRIX"] == "1" else { throw XCTSkip("explicit hardware quality experiment") }
  let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["PADINK_VIDEO_MATRIX_OUTPUT"] ?? "/tmp/padink-video-matrix.json")
  let mode=try XCTUnwrap(CGDisplayCopyDisplayMode(CGMainDisplayID()))
  let native=CGSize(width:mode.pixelWidth,height:mode.pixelHeight)
  let sizes=[VideoGeometry.raster(source:native,drawable:CGSize(width:2360,height:1640)),native]
  var results=[Result]()
  for size in sizes {
   let w=Int(size.width),h=Int(size.height),base=EncoderSettings.bitrate(width:Int(size.width),height:Int(size.height))
   let rates=ProcessInfo.processInfo.environment["PADINK_VIDEO_BUDGET"] == "1" ? VideoSettings.dailyMegabits : Array(Set(VideoSettings.experimentMultipliers.map { Double(base)*$0/1e6 } + VideoSettings.experimentMegabits)).sorted()
   // Identical immutable frames are reused by every codec and rate at this raster.
   let frames=try (0..<8).map { try source(width:w,height:h,offset:$0*9) }
   for codec in VideoCodec.allCases { for rate in rates {
    let diagnostics=Diagnostics(),sink=Sink(),decoder=VideoDecoder(session:1,diagnostics:diagnostics)
    let settings=VideoSettings(resolution:.native,codec:codec,megabits:rate)
    let video=MacVideo(session:1,diagnostics:diagnostics,displayID:CGMainDisplayID(),settings:settings,extended:true)
    var result=Result(codec:codec == .hevc ? "HEVC":"H264",width:w,height:h,targetMbps:rate,frames:0,elapsed:0,actualMbps:0,peakSecondMbps:0,loopbackFPS:0,lumaPSNR:0,edgePSNR:0,encodeMs:nil,decodeMs:nil)
    video.onFrame={c,f in sink.config=c;sink.frame=f;sink.ready.signal()};video.onError={e in sink.error=e;sink.ready.signal()}
    let start=MonotonicClock.now;var bytes=0, mse=0.0,edge=0.0,compares=0.0,bins=[Int:Int]()
    do {
     try video.prepareEncoder(raster:size)
     for n in 0..<120 {
      let source=frames[n/15%frames.count]
      sink.error=nil;sink.config=nil;sink.frame=nil
      video.acceptRaw(source,time:start+UInt64(n)*1_000_000_000/60)
      guard sink.ready.wait(timeout:.now()+3) == .success else { throw VideoPipelineError.capture }
      if let e=sink.error { throw e }
      let frame=try XCTUnwrap(sink.frame)
      if let c=sink.config { try decoder.configure(try VideoConfig(c.encode())) }
      try decoder.decode(VideoFrame(payload:frame.encode(),keyframe:frame.key,codec:codec))
      let decoded=try XCTUnwrap(decoder.latest.take())
      bytes += frame.avcc.count; bins[Int((MonotonicClock.now-start)/1_000_000_000),default:0] += frame.avcc.count
      if n%15 == 0 { let e=error(source,decoded.buffer);mse += e.0;edge += e.1;compares += 1 }
      result.frames += 1
      let due=start+UInt64(n+1)*1_000_000_000/60,now=MonotonicClock.now
      if due>now { Thread.sleep(forTimeInterval:Double(due-now)/1e9) }
     }
    } catch { result.error=String(describing:error) }
    video.stop();video.queue.sync {};decoder.reset()
    result.elapsed=Double(MonotonicClock.now-start)/1e9;result.actualMbps=Double(bytes)*8/result.elapsed/1e6
    result.peakSecondMbps=Double(bins.values.max() ?? 0)*8/1e6;result.loopbackFPS=Double(result.frames)/result.elapsed
    result.lumaPSNR=10*log10(255*255/max(1e-10,mse/max(1,compares)));result.edgePSNR=10*log10(255*255/max(1e-10,edge/max(1,compares)))
    let metrics=diagnostics.report().metrics;result.encodeMs=metrics?.encodeMilliseconds;result.decodeMs=metrics?.decodeMilliseconds
    results.append(result);let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(results).write(to:root,options:.atomic)
    print("QUALITY \(result.codec) \(w)x\(h) target=\(rate) actual=\(result.actualMbps) edgePSNR=\(result.edgePSNR) frames=\(result.frames) error=\(result.error ?? "none")")
   }}
  }
 }
}
#endif
