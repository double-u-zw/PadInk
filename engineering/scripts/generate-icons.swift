#!/usr/bin/env swift
import AppKit

// Reproducible code-native PadInk icon. All paths/colors are owned here; no external assets.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: colorSpace, components: [r,g,b,a])! }
func icon(size: Int, to url: URL) throws {
 let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
 c.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
 let gradient = CGGradient(colorsSpace: colorSpace, colors: [color(0.04,0.11,0.2), color(0.08,0.26,0.35)] as CFArray, locations: [0,1])!
 c.drawLinearGradient(gradient, start: CGPoint(x: 512,y: 0), end: CGPoint(x: 512,y: 1024), options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
 let tablet = CGPath(roundedRect: CGRect(x: 168,y: 214,width: 688,height: 544), cornerWidth: 60, cornerHeight: 60, transform: nil)
 c.addPath(tablet); c.setFillColor(color(0.11,0.36,0.43)); c.fillPath()
 c.addPath(tablet); c.setStrokeColor(color(0.51,0.9,0.87)); c.setLineWidth(22); c.strokePath()
 c.addPath(CGPath(roundedRect: CGRect(x: 206,y: 252,width: 612,height: 468), cornerWidth: 28, cornerHeight: 28, transform: nil)); c.setFillColor(color(0.07,0.17,0.25)); c.fillPath()
 c.setLineCap(.round); c.setLineJoin(.round); c.setLineWidth(28); c.setStrokeColor(color(0.51,0.9,0.87))
 c.move(to: CGPoint(x: 290,y: 424)); c.addCurve(to: CGPoint(x: 460,y: 408), control1: CGPoint(x: 380,y: 608), control2: CGPoint(x: 375,y: 280)); c.addCurve(to: CGPoint(x: 624,y: 426), control1: CGPoint(x: 545,y: 526), control2: CGPoint(x: 525,y: 336)); c.strokePath()
 c.saveGState(); c.translateBy(x: 653,y: 390); c.rotate(by: -.pi / 5)
 c.addPath(CGPath(roundedRect: CGRect(x: -33,y: 64,width: 66,height: 390), cornerWidth: 22, cornerHeight: 22, transform: nil)); c.setFillColor(color(0.95,0.97,0.98)); c.fillPath()
 c.move(to: CGPoint(x: -33,y: 86)); c.addLine(to: CGPoint(x: 0,y: 0)); c.addLine(to: CGPoint(x: 33,y: 86)); c.closePath(); c.setFillColor(color(0.28,0.79,0.73)); c.fillPath()
 c.restoreGState()
 let image = c.makeImage()!; let representation = NSBitmapImageRep(cgImage: image)
 try representation.representation(using: .png, properties: [:])!.write(to: url)
}
for platform in ["Mac", "iPad"] {
 let assets = root.appendingPathComponent("Hosts/\(platform)/Assets.xcassets")
 let folder = assets.appendingPathComponent("AppIcon.appiconset")
 try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
 var entries = [[String:String]]()
 if platform == "Mac" {
  for size in [16,32,128,256,512] { for scale in [1,2] {
   let filename = "icon-\(size)@\(scale)x.png"; try icon(size: size * scale, to: folder.appendingPathComponent(filename))
   entries.append(["idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x","filename":filename])
  } }
 } else {
  for (size,scales) in [(20.0,[1,2]),(29.0,[1,2]),(40.0,[1,2]),(76.0,[1,2]),(83.5,[2])] {
   for scale in scales {
    let label = size == floor(size) ? String(Int(size)) : String(size)
    let filename = "icon-\(label)@\(scale)x.png"; try icon(size: Int(size * Double(scale)), to: folder.appendingPathComponent(filename))
    entries.append(["idiom":"ipad","size":"\(label)x\(label)","scale":"\(scale)x","filename":filename])
   }
  }
  try icon(size: 1024, to: folder.appendingPathComponent("icon-1024.png"))
  entries.append(["idiom":"ios-marketing","size":"1024x1024","scale":"1x","filename":"icon-1024.png"])
 }
 let info:[String:Any] = ["version":1,"author":"xcode"]
 try JSONSerialization.data(withJSONObject: ["images":entries,"info":info], options:[.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
 try JSONSerialization.data(withJSONObject: ["info":info], options:[.prettyPrinted,.sortedKeys]).write(to: assets.appendingPathComponent("Contents.json"))
}
print("Generated opaque sRGB Mac and iPad AppIcon assets")
