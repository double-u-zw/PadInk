import SwiftUI
import PadInkCore
import PadInkMacKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
 let coordinator = MacCoordinator()
 let navigation = MacNavigationModel()
 private var mainWindow: NSWindow?

 func applicationDidFinishLaunching(_ notification: Notification) {
  coordinator.beginDiagnosticSession()
  coordinator.start()
  show(.connection)
 }
 func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(.connection); return false }
 func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
 func applicationWillTerminate(_ notification: Notification) { coordinator.shutdown(); coordinator.endDiagnosticSession() }

 func show(_ page: MacPage) {
  navigation.selection = page
  NSApp.setActivationPolicy(.regular)
  if let mainWindow { mainWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
  let content = MacMainView(coordinator: coordinator, navigation: navigation)
  let window = NSWindow(contentViewController: NSHostingController(rootView: content))
  window.title = ProductIdentity.displayName
  window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
  window.setContentSize(NSSize(width: 780, height: 620)); window.minSize = NSSize(width: 540, height: 540)
  window.isReleasedWhenClosed = false; window.delegate = self
  window.setFrameAutosaveName("PadInk.MainWindow")
  if !window.setFrameUsingName("PadInk.MainWindow") { window.center() }
  mainWindow = window
  window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
 }
 func windowWillClose(_ notification: Notification) { mainWindow = nil; NSApp.setActivationPolicy(.accessory) }
}

@main struct PadInkMacApp: App {
 @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
 var body: some Scene {
  MenuBarExtra {
   MacMenuView(coordinator: delegate.coordinator, onNavigate: { delegate.show($0) })
  } label: {
   Image(systemName: "pencil.tip.crop.circle").accessibilityLabel("PadInk")
  }
  .menuBarExtraStyle(.window)
  .commands {
   CommandGroup(replacing: .appInfo) {
    Button("关于 PadInk") { delegate.show(.about) }
   }
   CommandGroup(replacing: .appSettings) {
    Button("设置…") { delegate.show(.settings) }.keyboardShortcut(",", modifiers: .command)
   }
   CommandGroup(replacing: .newItem) {
    Button("打开 PadInk") { delegate.show(.connection) }.keyboardShortcut("o", modifiers: .command)
   }
   CommandGroup(replacing: .help) {
    Button("PadInk 帮助") { delegate.show(.help) }
    Button("导出诊断…") { delegate.show(.diagnostics) }
   }
  }
 }
}
