import XCTest
@testable import PadInkCore

final class BuildIdentityTests: XCTestCase {
 func testStoreAndTestFlightShareBinaryWithoutDeveloperExpiryGuidance() {
  XCTAssertEqual(BuildIdentity.resolvedDistribution(declared: "testflight", receiptName: "receipt"), "appstore")
  XCTAssertEqual(BuildIdentity.resolvedDistribution(declared: "appstore", receiptName: "sandboxReceipt"), "testflight")
  XCTAssertEqual(BuildIdentity.resolvedDistribution(declared: "testflight", receiptName: nil), "testflight")
  XCTAssertEqual(BuildIdentity.resolvedDistribution(declared: "altstore", receiptName: "receipt"), "altstore")
  for distribution in ["appstore", "testflight", "unsigned"] {
   let build = BuildIdentity(version: "0.3.0", source: "label", channel: "release", distribution: distribution)
   XCTAssertFalse(build.usesProvisioningExpiryReminder)
   XCTAssertFalse(build.installationGuidance.contains("7 天"))
   if distribution == "appstore" { XCTAssertTrue(build.installationGuidance.contains("App Store")) }
  }
  XCTAssertTrue(BuildIdentity(version: "0.3.0", source: "label", distribution: "developer").usesProvisioningExpiryReminder)
  XCTAssertTrue(BuildIdentity(version: "0.3.0", source: "label", distribution: "altstore").usesProvisioningExpiryReminder)
 }
 func testEditionIsSeparateFromCandidateChannelAndInstallationMethod() {
  let dev = BuildIdentity(version: "0.3.0", source: "label", channel: "development", distribution: "altstore", variant: "development")
  let rc = BuildIdentity(version: "0.3.0", source: "label", channel: "rc", distribution: "altstore", variant: "release")
  XCTAssertEqual(dev.variant, .development); XCTAssertEqual(rc.variant, .release)
  XCTAssertTrue(dev.display.contains("开发版")); XCTAssertTrue(rc.display.contains("正式版"))
  XCTAssertEqual(dev.wireVersion, rc.wireVersion)
  var session = SessionDiagnostics(); session.applyBuild(dev)
  XCTAssertEqual(session.buildVariant, "development")
  XCTAssertEqual(BuildIdentity(version: "0.3.0", source: "label").variant, .release)
 }
 func testExactSourceLabelSurvivesExistingHello() throws {
  let build = BuildIdentity(version: "0.3.0", source: "33be0b0d98c0+012345abcdef")
  XCTAssertLessThanOrEqual(build.wireVersion.utf8.count, Hello.maxAppVersionBytes)
  let hello = Hello(connection: .controlInput, role: .mac, appVersion: build.wireVersion,
   deviceID: Data(count: 32), attachmentID: UUID(), generation: 1)
  XCTAssertEqual(try Hello(hello.encoded()).appVersion, build.wireVersion)
  XCTAssertTrue(build.wireVersion.contains(build.source))
 }
 func testReleaseProvenanceIsLocalAndWireLabelUnchanged() throws {
  let revision = String(repeating: "a", count: 40), digest = String(repeating: "b", count: 64)
  let build = BuildIdentity(version: "0.3.0", source: "cd73653+012345abcdef", build: "17", channel: "rc",
   distribution: "testflight", sourceRevision: revision, sourceDigest: digest)
  XCTAssertEqual(build.wireVersion, BuildIdentity(version: "0.3.0", source: build.source).wireVersion)
  XCTAssertEqual(build.sourceRevision, revision); XCTAssertEqual(build.sourceDigest, digest)
  XCTAssertTrue(build.display.contains("(17)")); XCTAssertTrue(build.display.contains("RC"))
  XCTAssertFalse(build.isDeveloperInstall); XCTAssertTrue(build.installationGuidance.contains("TestFlight"))
  XCTAssertFalse(build.installationGuidance.contains("7 天"))
  var session = SessionDiagnostics(); session.applyBuild(build)
  let decoded = try JSONDecoder().decode(SessionDiagnostics.self, from: JSONEncoder().encode(session))
  XCTAssertEqual(decoded.buildNumber, "17"); XCTAssertEqual(decoded.sourceDigest, digest)
  XCTAssertEqual(decoded.sourceRevision, revision); XCTAssertEqual(decoded.releaseChannel, "rc")
 }
 func testProvenanceRejectsPathsAndChannelControlsSigningHelp() {
  let malformed = BuildIdentity(version: "0.3.0", source: "label", build: "/private/build", channel: "rc", sourceRevision: "short", sourceDigest: "/private/source")
  XCTAssertEqual(malformed.build, "unknown"); XCTAssertNil(malformed.sourceRevision); XCTAssertNil(malformed.sourceDigest)
  XCTAssertFalse(malformed.isDeveloperInstall); XCTAssertFalse(malformed.installationGuidance.contains("7 天"))
  XCTAssertTrue(BuildIdentity(version: "0.3.0", source: "label", channel: "development", distribution: "developer").isDeveloperInstall)
  XCTAssertFalse(BuildIdentity(version: "0.3.0", source: "label", channel: "preview", distribution: "unsigned").isDeveloperInstall)
 }
 func testUnknownBuildAndOlderPlainPeerRemainReadable() throws {
  XCTAssertEqual(BuildIdentity(version: "0.3.0", source: nil).source, "unknown")
  XCTAssertEqual(BuildIdentity(version: "0.3.0", source: "/private/source").source, "unknown")
  let old = Hello(connection: .controlInput, role: .ipad, appVersion: "0.3.0",
   deviceID: Data(count: 32), attachmentID: UUID(), generation: 1)
  XCTAssertEqual(try Hello(old.encoded()).appVersion, "0.3.0")
 }
}
