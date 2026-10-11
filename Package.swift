// swift-tools-version: 5.9
import PackageDescription

// Layering (docs/ARCHITECTURE.md §1): PadInkCore (pure) <- PadInkTransport <- app kits <- app hosts.
// The kits hold all app logic so it runs under `swift test` on macOS; the Xcode app targets in
// Hosts/ only contain entry points. PadInkPadKit's UIKit parts are compiled for iPadOS only.
let package = Package(
 name: "PadInk",
 platforms: [.macOS(.v14), .iOS(.v17)],
 products: [
  .library(name: "PadInkCore", targets: ["PadInkCore"]),
  .library(name: "PadInkTransport", targets: ["PadInkTransport"]),
  .library(name: "PadInkMacKit", targets: ["PadInkMacKit"]),
  .library(name: "PadInkPadKit", targets: ["PadInkPadKit"]),
  .executable(name: "padink-replay", targets: ["padink-replay"]),
 ],
 targets: [
  .target(name: "PadInkCore"),
  .target(name: "PadInkTransport", dependencies: ["PadInkCore"]),
  .target(name: "PadInkMacKit", dependencies: ["PadInkCore", "PadInkTransport"], path: "Apps/Mac"),
  .target(name: "PadInkPadKit", dependencies: ["PadInkCore", "PadInkTransport"], path: "Apps/iPad"),
  // Mac-side real-application replay (REWRITE_BRIEF §11.1). Local only; never part of an app build.
  .target(name: "PadInkReplayKit", dependencies: ["PadInkCore"], path: "engineering/tools/ReplayKit"),
  .executableTarget(name: "padink-replay", dependencies: ["PadInkReplayKit", "PadInkMacKit", "PadInkCore"], path: "engineering/tools/Replay"),
  .testTarget(name: "PadInkCoreTests", dependencies: ["PadInkCore"]),
  .testTarget(name: "PadInkTransportTests", dependencies: ["PadInkTransport", "PadInkCore"]),
  .testTarget(name: "PadInkAppTests", dependencies: ["PadInkMacKit", "PadInkPadKit", "PadInkCore", "PadInkTransport"]),
  .testTarget(name: "PadInkReplayTests", dependencies: ["PadInkReplayKit", "PadInkCore"]),
 ]
)
