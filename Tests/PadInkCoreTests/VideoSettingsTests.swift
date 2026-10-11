import XCTest
@testable import PadInkCore
final class VideoSettingsTests: XCTestCase {
 func testBaselineAndCongestionPreserveOriginalLadder() {
  for transport in [TransportKind.usb, .wifi] {
   for quality in VideoQuality.allCases {
    let p = VideoProfile(quality, transport: transport)
    XCTAssertEqual(VideoSettings.baseline.targetBitrate(baseline: 80_000_000, profile: p), Int(80_000_000 * p.bitrateScale))
   }
  }
  let high = VideoSettings(multiplier: 2, megabits: 300)
  XCTAssertEqual(high.targetBitrate(baseline: 80_000_000, profile: VideoProfile()), 300_000_000)
  XCTAssertEqual(high.targetBitrate(baseline: 80_000_000, profile: VideoProfile(.reducedBitrate)), 40_000_000)
  XCTAssertEqual(high.targetBitrate(baseline: 80_000_000, profile: VideoProfile(.reducedBitrate, transport: .wifi)), 14_000_000)
 }
 func testDailyBudgetsNeverRiseDuringCongestionAndOldJSONSurvives() throws {
  let old = Data(#"{"resolution":"fiveK","codec":1,"multiplier":2,"megabits":160}"#.utf8)
  let saved = try JSONDecoder().decode(VideoSettings.self, from: old)
  XCTAssertEqual(saved.megabits, 160); XCTAssertEqual(saved.mode, .saved)
  XCTAssertEqual(try JSONDecoder().decode(VideoSettings.self, from: JSONEncoder().encode(saved)), saved)
  for mode in [VideoMode.standard, .hd, .automatic, .highQuality] {
   let settings = VideoSettings.daily(mode)
   XCTAssertEqual(settings.resolution, .native); XCTAssertEqual(settings.codec, .h264)
   XCTAssertEqual(settings.mode, mode)
   for transport in [TransportKind.usb, .wifi] {
    var previous = Int.max
    for quality in VideoQuality.allCases {
     let rate = settings.targetBitrate(baseline: 80_000_000, profile: VideoProfile(quality, transport: transport))
     XCTAssertLessThanOrEqual(rate, 20_000_000); XCTAssertLessThanOrEqual(rate, previous); previous = rate
    }
   }
  }
 }
 func testPresentationPressureDoesNotMistakeStaticContentOrOldEpochForCongestion() {
  let p = VideoPresentationPressure(), epoch = UUID()
  p.reset(epoch: epoch); p.received(epoch: epoch, now: 1)
  p.presented(epoch: epoch, received: 1, now: 20_000_000)
  XCTAssertFalse(p.congested(now: 1_000_000_000))
  p.received(epoch: epoch, now: 1_000_000_001)
  XCTAssertTrue(p.congested(now: 1_100_000_000))
  p.reset(epoch: UUID()); p.presented(epoch: epoch, received: 1, now: 2_000_000_000)
  XCTAssertFalse(p.congested(now: 2_000_000_001))
 }
 func testNativePreservesPixelsAndExperimentalRasterNeverUpscales() {
  let source = CGSize(width: 2940, height: 1912), drawable = CGSize(width: 2360, height: 1640)
  for choice in [VideoResolution.native, .fourK, .fiveK] {
   XCTAssertEqual(VideoGeometry.raster(source: source, drawable: drawable, resolution: choice, extended: true), source)
  }
  XCTAssertEqual(VideoGeometry.raster(source: source, drawable: drawable, resolution: .current, extended: true), CGSize(width: 2360, height: 1534))
  let fiveK = CGSize(width: 5120, height: 2880)
  XCTAssertEqual(VideoGeometry.raster(source: fiveK, drawable: drawable, resolution: .fiveK, extended: true), fiveK)
  XCTAssertEqual(VideoGeometry.raster(source: fiveK, drawable: drawable, resolution: .native, extended: false), CGSize(width: 4096, height: 2304))
 }
 func testHEVCConfigAndNALValidationAndLegacyBytes() throws {
  let c = VideoConfig(generation: 7, width: 5120, height: 2880, sps: Data([2]), pps: Data([3]), codec: .hevc, vps: Data([1]))
  XCTAssertEqual(try VideoConfig(c.encode()), c)
  XCTAssertEqual(try VideoFeedback(VideoFeedback(c).encode()), VideoFeedback(c))
  let old = VideoConfig(generation: 1, width: 640, height: 360, sps: Data([7]), pps: Data([8]))
  XCTAssertEqual(old.encode().count, 18); XCTAssertEqual(try VideoConfig(old.encode()), old)
  let frame = VideoFrame(generation: 7, id: 1, captureTime: 0, key: true, avcc: Data([0,0,0,2,38,1]))
  XCTAssertNoThrow(try VideoFrame(payload: frame.encode(), keyframe: true, codec: .hevc))
  XCTAssertThrowsError(try VideoFrame(payload: frame.encode(), keyframe: true))
  var malformed = c.encode(); malformed.removeLast(); XCTAssertThrowsError(try VideoConfig(malformed))
 }
 func testInvalidRatesDoNotTrapAndUseBaseline() {
  for value in [Double.nan, .infinity, -1, 1e99] {
   let settings = VideoSettings(megabits: value)
   XCTAssertFalse(settings.isValid)
   XCTAssertEqual(settings.targetBitrate(baseline: 80_000_000, profile: VideoProfile()), 80_000_000)
  }
 }
}
