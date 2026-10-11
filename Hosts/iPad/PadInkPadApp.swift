import SwiftUI
import PadInkPadKit
import PadInkCore

private enum Shared {
 #if DEBUG
 static var fixture: String? {
  let arguments = ProcessInfo.processInfo.arguments
  guard let index = arguments.firstIndex(of: "-PadInkUIFixture"), arguments.indices.contains(index + 1) else { return nil }
  return arguments[index + 1]
 }
 #endif
 static var isPreview: Bool {
  #if DEBUG
  fixture != nil
  #else
  false
  #endif
 }
 static let coordinator: PadCoordinator = {
  let c = PadCoordinator()
  #if DEBUG
  if let fixture {
   let model = c.model
   model.macName = "MacBook Pro"
   model.peerVersion = "0.3.0"
   if ["connected", "wifi", "recovering", "video-recovery", "input-note"].contains(fixture) {
    model.connected = true; model.sessionActive = true
    model.phase = .active; model.transport = fixture == "wifi" ? "Wi-Fi" : "USB"
    model.status = "已连接 · \(model.transport)"
   }
   if fixture == "recovering" {
    model.connected = false; model.sessionActive = false; model.phase = .recovering
    model.status = "连接中断，正在自动重连；请检查数据线或同一 Wi-Fi，并保持两端应用打开"
   }
   if fixture == "video-recovery" {
    model.phase = .recovering; model.status = "画面恢复中"
    model.videoNote = "画面连接正在恢复；输入连接仍在"
   }
   if fixture == "input-note" { model.lastInputNote = "操作已安全结束，请重新落笔" }
   if fixture == "error" {
    model.phase = .needsAttention
    model.status = "版本不兼容：请更新 Mac 和 iPad 两端，再重新连接"
   }
   if fixture == "pairing" { model.pairing = PairingRequest(deviceID: Data([1]), name: "MacBook Pro") }
   return c
  }
  #endif
  c.beginDiagnosticSession(); c.start(); return c
 }()
}

private final class PadInkPadAppDelegate: NSObject, UIApplicationDelegate {
 func applicationWillTerminate(_ application: UIApplication) { if !Shared.isPreview { Shared.coordinator.endDiagnosticSession() } }
}

@main struct PadInkPadApp: App {
 @UIApplicationDelegateAdaptor(PadInkPadAppDelegate.self) private var delegate
 @Environment(\.scenePhase) private var phase
 var body: some Scene {
  WindowGroup {
   Group {
    #if DEBUG
    if let fixture = Shared.fixture { PadUIFixtureScreen(coordinator: Shared.coordinator, page: fixture) }
    else { PadScreen(coordinator: Shared.coordinator) }
    #else
    PadScreen(coordinator: Shared.coordinator)
    #endif
   }
    .onChange(of: phase) { _, phase in
     guard !Shared.isPreview else { return }
     if phase == .active { Shared.coordinator.resume() } else { Shared.coordinator.suspend() }
    }
  }
 }
}
