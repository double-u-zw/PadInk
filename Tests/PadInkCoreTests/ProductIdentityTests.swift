import XCTest
@testable import PadInkCore

final class ProductIdentityTests: XCTestCase {
 func testDevelopmentAndReleaseNamespacesAreIndependent() {
  let dev = ProductIdentity.namespace(for: .development)
  let release = ProductIdentity.namespace(for: .release)
  XCTAssertEqual(dev.displayName, "PadInk")
  XCTAssertEqual(release.displayName, "PadInk")
  XCTAssertNotEqual(dev.keychainService, release.keychainService)
  XCTAssertNotEqual(dev.usbLoopbackPort, release.usbLoopbackPort)
  XCTAssertNotEqual(dev.bonjourServiceType, release.bonjourServiceType)
  XCTAssertEqual(release.keychainService, "dev.padink03.trust")
  XCTAssertEqual(release.usbLoopbackPort, 42371)
  XCTAssertEqual(release.bonjourServiceType, "_pnk2._tcp")
  for type in [dev.bonjourServiceType, release.bonjourServiceType] {
   XCTAssertTrue(type.hasSuffix("._tcp"))
   XCTAssertTrue((1...15).contains(type.dropFirst().dropLast(5).count))
  }
 }

 func testNoDurableIdentifierIsSharedWithLegacyVersions() {
  XCTAssertFalse(ProductIdentity.Legacy.keychainServices.contains(ProductIdentity.keychainService))
  XCTAssertFalse(ProductIdentity.keychainService.hasPrefix(ProductIdentity.Legacy.bundleIDPrefix))
  XCTAssertFalse(ProductIdentity.Legacy.ports.contains(ProductIdentity.usbLoopbackPort))
  XCTAssertFalse(ProductIdentity.bonjourServiceType.hasPrefix(ProductIdentity.Legacy.bonjourPrefix))
 }

 func testPublicBrandKeepsExistingTrustAndTransportNamespaces() {
  XCTAssertEqual(ProductIdentity.displayName, "PadInk")
  XCTAssertEqual(ProductIdentity.keychainService, "dev.padink03.trust")
  XCTAssertEqual(ProductIdentity.usbLoopbackPort, 42371)
  XCTAssertEqual(ProductIdentity.bonjourServiceType, "_pnk2._tcp")
 }

 func testBonjourServiceTypeIsValid() {
  // RFC 6763: "_" + 1–15 chars of letters/digits/hyphen, then "._tcp".
  let type = ProductIdentity.bonjourServiceType
  XCTAssertTrue(type.hasPrefix("_") && type.hasSuffix("._tcp"))
  let name = type.dropFirst().dropLast(5)
  XCTAssertTrue((1...15).contains(name.count))
  XCTAssertTrue(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
 }

 func testUSBPortIsUnprivilegedAndUserRange() {
  // Outside the 49152–65535 ephemeral range, where outgoing sockets can already hold it.
  XCTAssertTrue((1024...49151).contains(ProductIdentity.usbLoopbackPort))
 }
}
