import XCTest
@testable import PadInkCore
final class VideoAdaptationTests: XCTestCase {
 func testCongestionLowersBitrateThenFPSAndRecoveryWaitsForStability() {
  var a = VideoAdaptation()
  XCTAssertNil(a.update(congested: true, now: 0))
  XCTAssertEqual(a.update(congested: true, now: 1_000_000_000), VideoProfile(.reducedBitrate))
  XCTAssertEqual(a.update(congested: true, now: 3_000_000_000), VideoProfile(.reducedFrameRate))
  XCTAssertNil(a.update(congested: false, now: 4_000_000_000))
  XCTAssertNil(a.update(congested: false, now: 13_999_999_999))
  XCTAssertEqual(a.update(congested: false, now: 14_000_000_000), VideoProfile())
 }
 func testTransientCongestionDoesNotChangeQualityAndFlappingDoesNotRestoreIt() {
  var a = VideoAdaptation()
  for t in 0..<10 { _ = a.update(congested: t % 2 == 0, now: UInt64(t) * 500_000_000) }
  XCTAssertEqual(a.profile, VideoProfile())
  _ = a.update(congested: true, now: 10_000_000_000); _ = a.update(congested: true, now: 13_000_000_000)
  _ = a.update(congested: false, now: 14_000_000_000); _ = a.update(congested: true, now: 15_000_000_000)
  _ = a.update(congested: false, now: 23_000_000_000)
  XCTAssertEqual(a.profile, VideoProfile(.reducedFrameRate))
 }
}
