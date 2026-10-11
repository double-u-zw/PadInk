#if DEBUG && canImport(CoreVideo)
import Foundation
import CoreVideo
/// One explicitly requested local NV12 frame per process for same-source comparisons.
/// Disabled in Release; never saves documents or images during normal operation.
public enum VideoReferenceCapture {
 public static var enabled: Bool { ProcessInfo.processInfo.environment["PADINK_VIDEO_REFERENCE"] == "1" }
 private static let lock = NSLock()
 private static var saved = false
 public static func save(_ buffer: CVPixelBuffer, frame: UInt64, session: UInt64, role: String) {
  guard frame == 120, enabled else { return }
  lock.lock(); guard !saved else { lock.unlock(); return }; saved = true; lock.unlock()
  DispatchQueue(label: "padink.video.reference", qos: .utility).async {
   guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return }
   let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
   CVPixelBufferLockBaseAddress(buffer, .readOnly)
   var data = Data(capacity: w*h*3/2)
   for p in 0..<2 {
    let ptr = CVPixelBufferGetBaseAddressOfPlane(buffer,p)!, stride = CVPixelBufferGetBytesPerRowOfPlane(buffer,p)
    for y in 0..<(p == 0 ? h : h/2) { data.append(ptr.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self),count:w) }
   }
   CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
   let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("\(ProductIdentity.displayName) Video Reference")
   do {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let name = "\(role)-s\(session)-f\(frame)-\(w)x\(h).nv12"
    try data.write(to:root.appendingPathComponent(name),options:.atomic)
   } catch { /* A diagnostic experiment must never interfere with the stream. */ }
  }
 }
 /// The same opt-in sample after the production iPad shader and viewport scaling. The caller
 /// copies only frame 120; file IO happens off the render queue and never runs in normal use.
 public static func saveRendered(_ data: Data, width: Int, height: Int, frame: UInt64, session: UInt64) {
  guard enabled, frame == 120 else { return }
  DispatchQueue(label: "padink.video.reference.rendered", qos: .utility).async {
   let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("\(ProductIdentity.displayName) Video Reference")
   do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try data.write(to: root.appendingPathComponent("rendered-s\(session)-f\(frame)-\(width)x\(height).bgra"), options: .atomic)
   } catch { /* Diagnostic capture must not interrupt presentation. */ }
  }
 }
}
#endif
