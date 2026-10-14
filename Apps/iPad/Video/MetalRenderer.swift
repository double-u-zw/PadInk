import MetalKit
import PadInkCore
/// NV12 -> BT.709 Metal presentation, ported from Baseline v0.1.0 (byte-identical in 0.2.0).
/// Geometry follows the actual decoded frame; the presented handler reports the geometry generation
/// that really reached the screen (presented-generation gating). Platform-neutral MetalKit.
public final class MetalRenderer:NSObject,MTKViewDelegate {
 public let presentationPressure = VideoPresentationPressure()
 public var performanceRenderingPaused = false
 public let device:MTLDevice
 private let commands:MTLCommandQueue,pipeline:MTLRenderPipelineState
 private var cache:CVMetalTextureCache?
 private let slots=DispatchSemaphore(value:2)
 private let diagnostics:Diagnostics
 public var latest:Latest<DecodedFrame>?
 public var session:UInt64=0
 public var inputContext:InputContext?
 public private(set) var videoEpoch:UUID?
 public var geometry=VideoGeometry(source:CGSize(width:16,height:9),bounds:.zero)
 public var willRenderGeometry:((VideoGeometry)->UInt32)?,didPresentGeometry:((UInt32)->Void)?
 private var submittedGeometry:UInt32=0
 private var last:DecodedFrame?,lastPresented:UInt64=0
 public init(diagnostics:Diagnostics)throws {
  guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else{throw DecodeError.hardware};self.device=device;commands=queue;self.diagnostics=diagnostics
  let library=try device.makeLibrary(source:"""
  #include <metal_stdlib>
  using namespace metal;
  struct V {float4 position [[position]]; float2 uv;};
  vertex V vertexMain(uint id [[vertex_id]]) {
   float2 p[4]={float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
   float2 uv[4]={float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
   return {float4(p[id],0,1),uv[id]};
  }
  fragment float4 fragmentMain(V v [[stage_in]],texture2d<float> y [[texture(0)]],texture2d<float> uv [[texture(1)]]) {
   constexpr sampler s(filter::linear,address::clamp_to_edge);
   float l=(y.sample(s,v.uv).r-16.0/255.0)*(255.0/219.0);
   float2 c=(uv.sample(s,v.uv).rg-float2(128.0/255.0))*(255.0/224.0);
   return float4(l+1.5748*c.y,l-0.187324*c.x-0.468124*c.y,l+1.8556*c.x,1);
  }
  """,options:nil)
  let descriptor=MTLRenderPipelineDescriptor();descriptor.vertexFunction=library.makeFunction(name:"vertexMain");descriptor.fragmentFunction=library.makeFunction(name:"fragmentMain");descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
  pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
  super.init();CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,device,nil,&cache)
 }
 public func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize){geometry.bounds=view.bounds}
 public func clear(){performanceRenderingPaused=false;last=nil;latest?.clear();lastPresented=0;submittedGeometry=0;videoEpoch=nil}
 /// Main thread. A new B cannot reuse an old decoded picture or its presentation completion.
 /// Input identity/contact are independent and remain valid during video-only recovery.
 public func replaceVideoSource(_ source:Latest<DecodedFrame>,epoch:UUID){clear();latest=source;videoEpoch=epoch;presentationPressure.reset(epoch:epoch)}
 public func invalidateInputGeometry(){submittedGeometry=0}
 public func draw(in view:MTKView){
  if diagnostics.performance.enabled && performanceRenderingPaused { return }
  if let frame=latest?.take(){last=frame}
  guard last != nil,slots.wait(timeout:.now()) == .success else{return}
  let acquireStart = diagnostics.performance.enabled ? MonotonicClock.now : 0
  guard let cache,let descriptor=view.currentRenderPassDescriptor,let drawable=view.currentDrawable,let command=commands.makeCommandBuffer() else{slots.signal();return}
  diagnostics.performance.record(PerformanceEvent("video.drawableAcquire", generation: session, start: acquireStart, end: MonotonicClock.now))
  // Acquiring a drawable can wait for the previous presentation. Use the newest decode after
  // that wait, not the picture that happened to be ready at the beginning of this draw callback.
  if let frame=latest?.take(){last=frame}
  guard let frame=last else{slots.signal();return}
  let buffer=frame.buffer;var yt:CVMetalTexture?,uvt:CVMetalTexture?
  let a=CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,buffer,nil,.r8Unorm,CVPixelBufferGetWidthOfPlane(buffer,0),CVPixelBufferGetHeightOfPlane(buffer,0),0,&yt)
  let b=CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,buffer,nil,.rg8Unorm,CVPixelBufferGetWidthOfPlane(buffer,1),CVPixelBufferGetHeightOfPlane(buffer,1),1,&uvt)
  guard a==kCVReturnSuccess,b==kCVReturnSuccess,let yt,let uvt,let y=CVMetalTextureGetTexture(yt),let uv=CVMetalTextureGetTexture(uvt),let encoder=command.makeRenderCommandEncoder(descriptor:descriptor) else{slots.signal();return}
  geometry=VideoGeometry(source:CGSize(width:CVPixelBufferGetWidth(buffer),height:CVPixelBufferGetHeight(buffer)),bounds:view.bounds)
  let geometryRevision=willRenderGeometry?(geometry) ?? 0
  let rect=geometry.rect;let sx=view.drawableSize.width/view.bounds.width,sy=view.drawableSize.height/view.bounds.height
  diagnostics.updateVideo { $0.drawableWidth = Int(view.drawableSize.width); $0.drawableHeight = Int(view.drawableSize.height); $0.viewportWidth = Int(rect.width*sx); $0.viewportHeight = Int(rect.height*sy) }
  encoder.setViewport(MTLViewport(originX:rect.minX*sx,originY:rect.minY*sy,width:rect.width*sx,height:rect.height*sy,znear:0,zfar:1));encoder.setRenderPipelineState(pipeline)
  encoder.setFragmentTexture(y,index:0);encoder.setFragmentTexture(uv,index:1);encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4);encoder.endEncoding()
  let sid=session,fid=frame.frame.id;let isNew=fid != lastPresented
  #if DEBUG
  if isNew, fid == 120, VideoReferenceCapture.enabled {
   let texture = drawable.texture, width = texture.width, height = texture.height
   let stride = ((width * 4 + 255) / 256) * 256
   if let copy = device.makeBuffer(length: stride * height, options: .storageModeShared), let blit = command.makeBlitCommandEncoder() {
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1), to: copy, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * height)
    blit.endEncoding()
    command.addCompletedHandler { command in
     guard command.status == .completed else { return }
     var data = Data(capacity: width * height * 4)
     for y in 0..<height { data.append(copy.contents().advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width * 4) }
     VideoReferenceCapture.saveRendered(data, width: width, height: height, frame: fid, session: sid)
    }
   }
  }
  #endif
  if isNew || geometryRevision != submittedGeometry {
   submittedGeometry=geometryRevision
   if isNew{lastPresented=fid;diagnostics.mark("video.renderSubmitted",session:sid,item:fid,sourceTime:frame.frame.captureTime,geometryGeneration:geometryRevision)}
   let videoContext = inputContext.flatMap { input in videoEpoch.map { VideoDecodeContext(attachment:input,epoch:$0) } }
   let presented = VideoDecodeContext.presentedCallback(context: videoContext, current: { [weak self] in
    guard let self, let input=self.inputContext, let epoch=self.videoEpoch else{return nil}
    return VideoDecodeContext(attachment:input,epoch:epoch)
   }, presented: { [weak self] in self?.didPresentGeometry?(geometryRevision) })
   #if targetEnvironment(simulator)
   // Simulator SDK does not expose drawable presentation notifications. This permits UI
   // testing after GPU completion, without claiming physical presentation/latency validation.
   command.addCompletedHandler { command in
    guard command.status == .completed else { return }
    DispatchQueue.main.async { presented() }
   }
   #else
   drawable.addPresentedHandler{[diagnostics,presentationPressure] d in
    guard d.presentedTime>0 else{return}
    DispatchQueue.main.async { presented() }
    guard isNew else{return}
    let time=UInt64(d.presentedTime*1e9)
    if let epoch=videoContext?.epoch { presentationPressure.presented(epoch:epoch,received:frame.received,now:time) }
    diagnostics.mark("video.presented",session:sid,item:fid,time:time,sourceTime:frame.frame.captureTime,geometryGeneration:geometryRevision)
    diagnostics.mark("video.receiveToPresent",session:sid,item:fid,time:time,sourceTime:frame.received,value:Double(time>=frame.received ? time-frame.received:0)/1e6)
   }
   #endif
  }
  command.addCompletedHandler{[slots] _ in _=yt;_=uvt;_=buffer;slots.signal()};command.present(drawable);command.commit()
 }
}
