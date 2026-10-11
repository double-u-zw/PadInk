import XCTest
import CoreGraphics
@testable import PadInkReplayKit

final class InkPlacementTests: XCTestCase {
 let ink = Data("""
 <inkml:ink xmlns:inkml="urn:inkml"><inkml:traceFormat><inkml:channel name="X"/><inkml:channel name="Y"/></inkml:traceFormat><inkml:channelProperty channel="X" name="resolution" value="1000" units="1/cm"/><inkml:channelProperty channel="Y" name="resolution" value="1000" units="1/cm"/><inkml:trace>0 0,100 200</inkml:trace></inkml:ink>
 """.utf8)
 func parse(name:String="ink1.xml",x:Int=12700,group:Bool=false,id:String="stable")throws->[InkPlacement.Part] {
  let cp="<p:contentPart r:id=\"r1\"><p:cNvPr id=\"4\"/><a:creationId id=\"\(id)\"/><a:xfrm><a:off x=\"\(x)\" y=\"25400\"/></a:xfrm></p:contentPart>"
  let g="<p:grpSp><p:grpSpPr><a:xfrm><a:off x=\"1000\" y=\"2000\"/><a:ext cx=\"10\" cy=\"10\"/><a:chOff x=\"1000\" y=\"2000\"/><a:chExt cx=\"10\" cy=\"10\"/></a:xfrm></p:grpSpPr>\(cp)</p:grpSp>"
  let slide=Data("<p:sld xmlns:p=\"urn:p\" xmlns:r=\"urn:r\" xmlns:a=\"urn:a\">\(group ? g:cp)</p:sld>".utf8)
  let rel=Data("<Relationships><Relationship Id=\"r1\" Target=\"../ink/\(name)\"/></Relationships>".utf8)
  return try InkPlacement.parse(slide:slide,relationships:rel,ink:["ppt/ink/\(name)":ink])
 }
 func testRenamedAndRegroupedPartsPersistWithStableIdentity()throws {
  let a=try parse(),b=try parse(name:"ink88.xml",group:true)
  XCTAssertTrue(InkPlacement.compare(a,b).passed)
  XCTAssertEqual(a[0].traces[0][0],CGPoint(x:1,y:2))
  XCTAssertEqual(a[0].traces[0][1].x,1+36000.0/12700,accuracy:1e-10)
 }
 func testPlacementChangeCannotHideBehindIdenticalRawInk()throws {
  let r=InkPlacement.compare(try parse(),try parse(x:25400))
  XCTAssertTrue(r.bytesIdentical);XCTAssertFalse(r.placementIdentical);XCTAssertFalse(r.passed)
 }
 func testChangedIdentityOrEmptyDocumentCannotPass()throws {
  XCTAssertFalse(InkPlacement.compare(try parse(),try parse(id:"replacement")).passed)
  XCTAssertFalse(InkPlacement.compare([],[]).passed)
 }
 func testRecordedReorderedPowerPointEvidence()throws {
  for name in ["replay-hid","replay-private"] {
   let dir=FixtureTests.persistenceURL.appendingPathComponent(name, isDirectory:true)
   let a=try InkPlacement.read(dir.appendingPathComponent("before-reopen.pptx")),b=try InkPlacement.read(dir.appendingPathComponent("after-reopen.pptx"))
   XCTAssertEqual(a.count,85);XCTAssertTrue(InkPlacement.compare(a,b).passed)
  }
 }
}
