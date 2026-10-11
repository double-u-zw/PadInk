import AppKit
import SwiftUI
import PadInkCore
import PadInkMacKit

// Offline fixtures of the production SwiftUI views. The coordinator is never started:
// no Keychain, USB, LAN, screen capture pipeline, PadInk permissions or input injection are used.
// Compile against the objects from an existing `swift test` run (see docs/开发者指南.md).
// Optional --onscreen briefly shows and captures only this fixture window to include native vibrancy.
@main
@MainActor
private enum RCUIRenderer {
 private struct Shot {
  let name: String
  let page: MacPage
  let width: CGFloat
  let height: CGFloat
  let populate: (MacModel) -> Void
  var menu = false
 }

 static func main() throws {
  let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) ?? "build/rc-ui/screenshots", isDirectory: true)
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  let onscreen = CommandLine.arguments.contains("--onscreen")
  let previousApp = NSWorkspace.shared.frontmostApplication
  NSApplication.shared.setActivationPolicy(onscreen ? .regular : .prohibited)
  defer {
   if onscreen { previousApp?.activate(options: []) }
  }
  let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  if let icon = NSImage(contentsOf: sourceRoot.appendingPathComponent("Hosts/Mac/Assets.xcassets/AppIcon.appiconset/icon-512@2x.png")) {
   NSApplication.shared.applicationIconImage = icon
  }
  let active: (MacModel) -> Void = { model in
   model.phase = .active; model.connected = true; model.transport = "USB"
   model.status = "已连接 · USB"; model.peerName = "iPad Pro"
   model.peerVersion = "0.3.0（构建 1）"; model.raster = "2360 × 1640 · 60 fps"
   model.trustedDevices = [PairingRequest(deviceID: Data(repeating: 1, count: 32), name: "iPad Pro")]
  }
  let waiting: (MacModel) -> Void = { _ in }
  let shots = [
   Shot(name: "mac-first-open", page: .connection, width: 780, height: 620, populate: { model in
    model.screenRecordingGranted = false; model.accessibilityGranted = false
   }),
   Shot(name: "mac-waiting-minimum", page: .connection, width: 540, height: 560, populate: waiting),
   Shot(name: "mac-long-device-name", page: .connection, width: 540, height: 560, populate: { model in
    active(model); model.peerName = String(repeating: "工作用 iPad ", count: 6)
   }),
   Shot(name: "mac-waiting-narrow", page: .connection, width: 640, height: 620, populate: waiting),
   Shot(name: "mac-connected-usb", page: .connection, width: 780, height: 620, populate: active),
   Shot(name: "mac-connected-wifi-roomy", page: .connection, width: 900, height: 720, populate: { model in
    active(model); model.transport = "Wi-Fi"; model.status = "已连接 · Wi-Fi"
    model.usbNote = "USB 暂未连接，当前通过 Wi-Fi 使用。"
   }),
   Shot(name: "mac-waiting-for-video", page: .connection, width: 780, height: 620, populate: { model in
    model.phase = .waitingForVideo; model.connected = true; model.peerName = "iPad Pro"
    model.status = "已连接，等待画面"; model.videoNote = "正在准备画面，请稍等。"
   }),
   Shot(name: "mac-recovering", page: .connection, width: 780, height: 620, populate: { model in
    model.phase = .recovering; model.peerName = "iPad Pro"
    model.status = "连接中断，正在自动重连；请检查数据线或同一 Wi-Fi，并保持两端应用打开"
   }),
   Shot(name: "mac-attention", page: .connection, width: 640, height: 620, populate: { model in
    model.phase = .needsAttention
    model.status = "版本不兼容：请同时更新 Mac 和 iPad，再重新连接"
    model.needsUpdate = "Mac 和 iPad 需要使用相同版本的 PadInk。"
   }),
   Shot(name: "mac-usb-pairing", page: .connection, width: 780, height: 620, populate: { model in
    model.phase = .connecting; model.status = "请在两端允许配对"
    model.pairing = PairingRequest(deviceID: Data(repeating: 2, count: 32), name: "新 iPad")
   }),
   Shot(name: "mac-settings", page: .settings, width: 780, height: 620, populate: active),
   Shot(name: "mac-help", page: .help, width: 780, height: 620, populate: active),
   Shot(name: "mac-diagnostics", page: .diagnostics, width: 780, height: 620, populate: { model in
    active(model); model.lastInputNote = "应用窗口已改变，请重新落笔。"
   }),
   Shot(name: "mac-about", page: .about, width: 780, height: 620, populate: active),
   Shot(name: "mac-menu", page: .connection, width: 340, height: 390, populate: active, menu: true),
  ]
  var index = [[String: Any]]()
  for shot in shots {
   for dark in [false, true] {
    let coordinator = MacCoordinator()
    coordinator.model.screenRecordingGranted = true
    coordinator.model.accessibilityGranted = true
    shot.populate(coordinator.model)
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    NSApplication.shared.appearance = appearance
    let view: AnyView
    if shot.menu {
     view = AnyView(MacMenuView(coordinator: coordinator, onNavigate: { _ in }))
    } else {
     view = AnyView(MacMainView(coordinator: coordinator, navigation: MacNavigationModel(selection: shot.page)))
    }
    let name = "\(shot.name)-\(dark ? "dark" : "light").png"
    let size = CGSize(width: shot.width, height: shot.height)
    let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
     .environment(\.controlActiveState, .active)
     .background(Color(nsColor: .windowBackgroundColor)))
    host.appearance = appearance
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: onscreen && !shot.menu ? [.titled, .closable] : [.borderless], backing: .buffered, defer: false)
    window.hasShadow = false; window.backgroundColor = .windowBackgroundColor
    window.contentView = host
    defer { window.orderOut(nil); window.contentView = nil }
    if onscreen {
     window.title = "PadInk · 界面预览"; window.center()
     window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.12))
    host.layoutSubtreeIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    if onscreen {
     let deadline = Date().addingTimeInterval(0.3)
     while Date() < deadline {
      if let event = NSApplication.shared.nextEvent(matching: .any, until: Date().addingTimeInterval(0.03), inMode: .default, dequeue: true) { NSApplication.shared.sendEvent(event) }
      NSApplication.shared.updateWindows()
     }
     let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
     capture.arguments = ["-x", "-l", String(window.windowNumber), output.appendingPathComponent(name).path]
     try capture.run(); capture.waitUntilExit()
     if capture.terminationStatus != 0 { throw CocoaError(.fileReadUnknown) }
    } else { try png.write(to: output.appendingPathComponent(name)) }
    index.append(["file": name, "page": String(describing: shot.page), "widthPoints": Int(size.width), "heightPoints": Int(size.height), "appearance": dark ? "dark" : "light", "fixture": true, "capture": onscreen ? "native-window" : "offline-hosting-view"])
    print(name)
   }
  }
  let manifest: [String: Any] = ["note": "Production SwiftUI views with fixed model fixtures. The coordinator is never started. These screenshots verify layout only, not real device connections or mirroring.", "screenshots": index]
  try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mac-screenshots.json"))
 }
}
