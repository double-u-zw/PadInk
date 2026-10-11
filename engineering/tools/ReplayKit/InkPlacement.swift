#if os(macOS)
import Foundation
import CoreGraphics

/// PowerPoint can rename and regroup ink parts on save. Identity comes from creationId;
/// InkML coordinates are local to the contentPart, not slide-global coordinates.
public enum InkPlacement {
 public struct Part: Equatable {
  public let id: String
  public let order: Int
  public let data: Data
  public let traces: [[CGPoint]] // slide points (1/72 inch)
 }
 public struct Persistence: Codable, Equatable {
  public let countBefore: Int, countAfter: Int
  public let bytesIdentical: Bool, placementIdentical: Bool
  public var passed: Bool { countBefore > 0 && bytesIdentical && placementIdentical }
 }
 public static func read(_ file: URL) throws -> [Part] {
  let ink = try PPTXInk.parts(of: file)
  let slide = try PPTXInk.run(["-p", file.path, "ppt/slides/slide1.xml"])
  let rels = try PPTXInk.run(["-p", file.path, "ppt/slides/_rels/slide1.xml.rels"])
  return try parse(slide: slide, relationships: rels, ink: Dictionary(uniqueKeysWithValues: ink.map { ($0.name, $0.data) }))
 }
 public static func compare(_ before: [Part], _ after: [Part]) -> Persistence {
  let ids = Set(before.map(\.id))
  guard ids.count == before.count, Set(after.map(\.id)).count == after.count, ids == Set(after.map(\.id)) else {
   return Persistence(countBefore: before.count, countAfter: after.count, bytesIdentical: false, placementIdentical: false)
  }
  let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
  return Persistence(countBefore: before.count, countAfter: after.count,
   bytesIdentical: before.allSatisfy { $0.data == byID[$0.id]?.data },
   placementIdentical: before.allSatisfy { p in
    guard let q = byID[p.id], p.traces.count == q.traces.count else { return false }
    return zip(p.traces, q.traces).allSatisfy { a,b in a.count == b.count && zip(a,b).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y) < 1e-7 } }
   })
 }
 static func parse(slide: Data, relationships: Data, ink: [String: Data]) throws -> [Part] {
  func root(_ data: Data) throws -> XMLElement {
   guard let n = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]).rootElement() else { throw InkMLError.malformed("XML root") }; return n
  }
  let tree = try root(slide), rels = try root(relationships)
  var targets = [String:String]()
  for r in children(rels,"Relationship") {
   guard let id = attr(r,"Id"), let target = attr(r,"Target"), attr(r,"TargetMode") != "External", targets[id] == nil else { throw InkMLError.malformed("relationship") }
   targets[id] = target
  }
  var ids = Set<String>()
  return try descendants(tree,"contentPart").map { cp in
   guard let rel = attr(cp,"id"), let target = targets[rel] else { throw InkMLError.malformed("ink relationship") }
   let name = String(URL(fileURLWithPath:"/ppt/slides").appendingPathComponent(target).standardized.path.dropFirst())
   guard let data = ink[name], let creation = descendants(cp,"creationId").first, let id = attr(creation,"id"), ids.insert(id).inserted,
    let nv = descendants(cp,"cNvPr").first, let order = attr(nv,"id").flatMap(Int.init), let xf = children(cp,"xfrm").first else { throw InkMLError.malformed("ink identity or transform") }
   try supported(xf)
   guard let off = children(xf,"off").first else { throw InkMLError.malformed("ink offset") }
   let xml = try root(data)
   var scale = [Double]()
   for axis in ["X","Y"] {
    guard let p = descendants(xml,"channelProperty").first(where: { attr($0,"channel") == axis && attr($0,"name") == "resolution" }), attr(p,"units") == "1/cm" else { throw InkMLError.malformed("ink resolution") }
    let resolution = try number(p,"value"); guard resolution > 0 else { throw InkMLError.malformed("ink resolution") }; scale.append(360000/resolution)
   }
   let ox = try number(off,"x"), oy = try number(off,"y")
   var traces = try InkML.traces(data).map { $0.xy.map { CGPoint(x:ox+$0.x*scale[0], y:oy+$0.y*scale[1]) } }
   var parent = cp.parent
   while let n = parent as? XMLElement {
    if n.localName == "grpSp" {
     guard let prop = children(n,"grpSpPr").first, let xf = children(prop,"xfrm").first,
      let o = children(xf,"off").first, let e = children(xf,"ext").first,
      let co = children(xf,"chOff").first, let ce = children(xf,"chExt").first else { throw InkMLError.malformed("group transform") }
     try supported(xf)
     let x = try number(o,"x"), y = try number(o,"y"), cx = try number(co,"x"), cy = try number(co,"y")
     let w = try number(ce,"cx"), h = try number(ce,"cy"), ew = try number(e,"cx"), eh = try number(e,"cy")
     guard w > 0, h > 0, ew > 0, eh > 0 else { throw InkMLError.malformed("group extent") }
     traces = traces.map { $0.map { CGPoint(x:x+($0.x-cx)*ew/w,y:y+($0.y-cy)*eh/h) } }
    }; parent = n.parent
   }
   traces = traces.map { $0.map { CGPoint(x:$0.x/12700,y:$0.y/12700) } }
   guard traces.flatMap({$0}).allSatisfy({$0.x.isFinite && $0.y.isFinite}) else { throw InkMLError.malformed("nonfinite placement") }
   return Part(id:id,order:order,data:data,traces:traces)
  }.sorted { $0.order < $1.order }
 }
 static func children(_ n:XMLElement,_ name:String)->[XMLElement] { (n.children ?? []).compactMap{$0 as? XMLElement}.filter{$0.localName == name} }
 static func descendants(_ n:XMLElement,_ name:String)->[XMLElement] { children(n,name)+(n.children ?? []).compactMap{$0 as? XMLElement}.flatMap{descendants($0,name)} }
 static func attr(_ n:XMLElement,_ name:String)->String? { n.attributes?.first{$0.localName == name}?.stringValue }
 static func number(_ n:XMLElement,_ name:String)throws->Double { guard let value=attr(n,name).flatMap(Double.init),value.isFinite else {throw InkMLError.malformed("number \(name)")};return value }
 static func supported(_ n:XMLElement)throws {
  guard attr(n,"rot").map({$0 == "0"}) ?? true, ["flipH","flipV"].allSatisfy({attr(n,$0).map({$0 == "0" || $0 == "false"}) ?? true}) else {throw InkMLError.malformed("rotated/flipped ink requires a supported transform; no verdict")}
 }
}
#endif
