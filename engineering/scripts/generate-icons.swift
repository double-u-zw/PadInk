#!/usr/bin/env swift
import AppKit

// Package extracted artwork: opaque iPad canvas and a transparent Mac rounded tile.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("engineering/assets/app-icon-source.png")
guard let source = NSBitmapImageRep(data: try Data(contentsOf: sourceURL))?.cgImage,
      source.width == source.height else {
 fatalError("Expected square icon artwork at \(sourceURL.path)")
}
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func icon(size: Int, mac: Bool = false, to url: URL) throws {
 let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: (mac ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
 let canvas = CGRect(x: 0, y: 0, width: size, height: size)
 let bounds = mac ? canvas.insetBy(dx: CGFloat(size) / 16, dy: CGFloat(size) / 16) : canvas
 if mac {
  let radius = CGFloat(size) * 0.18
  c.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
  c.clip()
 }
 c.setFillColor(CGColor(gray: 1, alpha: 1))
 c.fill(bounds)
 c.interpolationQuality = .high
 // Keep the tile size fixed while giving the emblem 15% more breathing room.
 let artworkBounds = bounds.insetBy(dx: bounds.width * 0.075, dy: bounds.height * 0.075)
 c.draw(source, in: artworkBounds)
 let representation = NSBitmapImageRep(cgImage: c.makeImage()!)
 try representation.representation(using: .png, properties: [:])!.write(to: url)
}
for platform in ["Mac", "iPad"] {
 let assets = root.appendingPathComponent("Hosts/\(platform)/Assets.xcassets")
 let folder = assets.appendingPathComponent("AppIcon.appiconset")
 try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
 var entries = [[String:String]]()
 if platform == "Mac" {
  for size in [16,32,128,256,512] { for scale in [1,2] {
   let filename = "icon-\(size)@\(scale)x.png"; try icon(size: size * scale, mac: true, to: folder.appendingPathComponent(filename))
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
print("Generated sRGB Mac (transparent corners) and iPad (opaque) AppIcon assets")
