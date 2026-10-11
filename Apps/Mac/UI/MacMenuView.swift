#if os(macOS)
import AppKit
import SwiftUI
import PadInkCore

public enum MacPage: String, CaseIterable, Identifiable {
 case connection, settings, help, diagnostics, about
 public var id: Self { self }
 public var title: String {
  switch self {
  case .connection: "连接"
  case .settings: "设置"
  case .help: "帮助"
  case .diagnostics: "诊断"
  case .about: "关于 PadInk"
  }
 }
 var symbol: String {
  switch self {
  case .connection: "ipad.and.arrow.forward"
  case .settings: "gearshape"
  case .help: "questionmark.circle"
  case .diagnostics: "stethoscope"
  case .about: "info.circle"
  }
 }
}

/// Navigation is local UI state. Connection facts always come from the coordinator's model.
public final class MacNavigationModel: ObservableObject {
 @Published public var selection: MacPage
 public init(selection: MacPage = .connection) { self.selection = selection }
}

/// The menu bar is a quick glance and a way back to the main window.
public struct MacMenuView: View {
 @ObservedObject private var model: MacModel
 private let coordinator: MacCoordinator
 private let onNavigate: (MacPage) -> Void

 public init(coordinator: MacCoordinator, onNavigate: @escaping (MacPage) -> Void = { _ in }) {
  self.coordinator = coordinator; model = coordinator.model; self.onNavigate = onNavigate
 }

 public var body: some View {
  VStack(alignment: .leading, spacing: 14) {
   HStack {
    Text("PadInk").font(.headline)
    Spacer()
    if model.connected || model.phase == .connecting { TransportBadge(transport: model.transport) }
   }
   HStack(alignment: .top, spacing: 10) {
    StatusSymbol(model: model).font(.title2)
    VStack(alignment: .leading, spacing: 4) {
     Text(model.presentationTitle).font(.headline)
     Text(model.presentationDetail).font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
   }
   if model.pairing != nil || model.lanPairing != nil {
    MacPairingConfirmation(model: model, coordinator: coordinator)
   } else if !model.permissionsGranted {
    Button("完成 Mac 授权…") { onNavigate(.connection) }.buttonStyle(.borderedProminent)
   }
   if model.paused {
    Button("重新连接", systemImage: "arrow.clockwise") { coordinator.userResume() }
   } else if model.canPause {
    Button("暂停连接", systemImage: "pause") { coordinator.userDisconnect() }
   }
   Divider()
   Button("打开 PadInk", systemImage: "macwindow") { onNavigate(.connection) }
    .keyboardShortcut("o", modifiers: .command)
   HStack {
    Button("设置…", systemImage: "gearshape") { onNavigate(.settings) }
    Spacer()
    Button("帮助", systemImage: "questionmark.circle") { onNavigate(.help) }
   }
   Divider()
   Button("退出 PadInk") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
  }
  .padding(16).frame(width: 300, alignment: .leading).tint(.teal)
 }
}

/// A normal Mac window with one focused connection page and clearly separated secondary pages.
public struct MacMainView: View {
 @ObservedObject private var model: MacModel
 @ObservedObject private var navigation: MacNavigationModel
 private let coordinator: MacCoordinator
 @State private var deviceToForget: PairingRequest?

 public init(coordinator: MacCoordinator, navigation: MacNavigationModel = MacNavigationModel()) {
  self.coordinator = coordinator; model = coordinator.model; self.navigation = navigation
 }

 public var body: some View {
  GeometryReader { geometry in
   HStack(spacing: 0) {
    if geometry.size.width >= 680 { sidebar; Divider() }
    VStack(spacing: 0) {
     if geometry.size.width < 680 { compactNavigation; Divider() }
     ScrollView {
      VStack(alignment: .leading, spacing: 22) {
       switch navigation.selection {
       case .connection: connectionPage
       case .settings: settingsPage
       case .help: helpPage
       case .diagnostics: diagnosticsPage
       case .about: aboutPage
       }
      }
      .frame(maxWidth: 640, alignment: .leading)
      .padding(geometry.size.width < 680 ? 24 : 28)
      .frame(maxWidth: .infinity, alignment: .topLeading)
     }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
   }
   .background(Color(nsColor: .windowBackgroundColor))
  }
  .frame(minWidth: 540, minHeight: 500).tint(.teal)
  .confirmationDialog("忘记这台 iPad？", isPresented: Binding(get: { deviceToForget != nil }, set: { if !$0 { deviceToForget = nil } }), titleVisibility: .visible) {
   if let device = deviceToForget {
    Button("忘记 \(device.name.isEmpty ? "iPad" : device.name)", role: .destructive) { coordinator.forgetDevice(device); deviceToForget = nil }
   }
   Button("取消", role: .cancel) { deviceToForget = nil }
  } message: {
   Text("配对记录将被移除，当前连接也会断开。下次连接需要在 Mac 和 iPad 两端重新确认配对。")
  }
 }

 private var sidebar: some View {
  VStack(alignment: .leading, spacing: 0) {
   HStack(spacing: 9) {
    Image(systemName: "pencil.tip.crop.circle").font(.title2).foregroundStyle(.tint)
    Text("PadInk").font(.title3.weight(.semibold))
   }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 18)
   List(selection: $navigation.selection) {
    ForEach([MacPage.connection, .settings, .help]) { page in
     Label(page.title, systemImage: page.symbol).tag(page)
    }
   }.listStyle(.sidebar).scrollContentBackground(.hidden)
   Button { navigation.selection = .about } label: {
    Label("关于 PadInk", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
   }.buttonStyle(.plain).padding(20)
  }.frame(width: 160).background(.regularMaterial)
 }

 private var compactNavigation: some View {
  HStack {
   Label("PadInk", systemImage: "pencil.tip.crop.circle").font(.headline)
   Spacer()
   Picker("页面", selection: $navigation.selection) {
    ForEach(MacPage.allCases) { Text($0.title).tag($0) }
   }.labelsHidden().pickerStyle(.menu).frame(width: 145)
  }.padding(.horizontal, 24).padding(.vertical, 12)
 }

 private var connectionPage: some View {
  Group {
   pageHeading("连接", detail: "让 iPad 成为 Mac 的书写与触控界面。")
   VStack(alignment: .leading, spacing: 18) {
    HStack(alignment: .top, spacing: 14) {
     StatusSymbol(model: model).font(.system(size: 30))
     VStack(alignment: .leading, spacing: 7) {
      Text(model.presentationTitle).font(.title2.weight(.semibold))
      Text(model.presentationDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
     }
     Spacer(minLength: 0)
    }
    if model.paused {
     Button("重新连接", systemImage: "arrow.clockwise") { coordinator.userResume() }.buttonStyle(.borderedProminent)
    } else if model.canPause {
     Button("暂停连接", systemImage: "pause") { coordinator.userDisconnect() }
    }
    if let notice = model.transportNotice { Label(notice, systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(.secondary) }
   }.card()

   if !model.permissionsGranted {
    MacPermissionSection(model: model, coordinator: coordinator)
   }
   MacPairingConfirmation(model: model, coordinator: coordinator)

   HStack(alignment: .top, spacing: 12) {
    transportCard("USB", symbol: "cable.connector", active: model.connected && model.transport == "USB",
                  connecting: model.phase == .connecting && model.transport == "USB",
                  detail: model.usbNote ?? "连接数据线后自动优先使用。")
    transportCard("Wi-Fi", symbol: "wifi", active: model.connected && model.transport == "Wi-Fi",
                  connecting: model.phase == .connecting && model.transport == "Wi-Fi",
                  detail: model.lanNote ?? "已配对设备在同一网络自动连接。")
   }

   if model.connected {
    VStack(alignment: .leading, spacing: 12) {
     Label("在 Mac 应用里选好工具，就可以开始", systemImage: "pencil.tip").font(.headline)
     Text("用 Pencil 书写；手指点击工具，双指滚动或捏合缩放。文稿由 Mac 上的应用保存，请照常保存。")
      .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
     Button("查看操作帮助") { navigation.selection = .help }
    }
   } else if model.phase == .waiting && model.permissionsGranted {
    VStack(alignment: .leading, spacing: 14) {
     Text("第一次连接").font(.headline)
     instructionRow("cable.connector", title: "用数据线连接 Mac 与 iPad", detail: "解锁 iPad；如有系统提示，选择“信任此电脑”。")
     instructionRow("ipad", title: "在 iPad 打开 PadInk", detail: "保持应用在前台，在两端确认配对。画面出现后即可书写。")
     Button("通过 Wi-Fi 连接…") { navigation.selection = .settings }
    }
   }
   if let note = model.actionableUpdateNote { actionNote(note, symbol: "arrow.down.circle") }
   if let note = model.actionableVideoNote { actionNote(note, symbol: "display.trianglebadge.exclamationmark") }
   if let note = model.actionableInputNote { actionNote(note, symbol: "pencil.tip") }
   if let note = model.actionableZoomNote { actionNote(note, symbol: "plus.magnifyingglass") }
   if model.buildIdentity.isDeveloperInstall, let note = model.signingWarning { actionNote(note, symbol: "calendar.badge.exclamationmark") }
  }
 }

 private var settingsPage: some View {
  Group {
   pageHeading("设置", detail: "管理 Mac 权限、连接方式与配对设备。")
   MacPermissionSection(model: model, coordinator: coordinator)
   VStack(alignment: .leading, spacing: 14) {
    Label("Wi-Fi 连接", systemImage: "wifi").font(.headline)
    Text("已用 USB 配对：两端接入同一网络，拔线后会自动尝试 Wi-Fi。\n首次无线配对：在 iPad“设置 › 连接与设备”开启 Wi-Fi 配对，再在这里选择 iPad。")
     .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    if model.lanDevices.isEmpty {
     Label("尚未发现附近的 iPad", systemImage: "ipad").foregroundStyle(.secondary)
     Text("保持 iPad 上的 PadInk 在前台，并允许两端的本地网络权限。")
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    } else {
     ForEach(model.lanDevices) { peer in
      HStack {
       Label(peer.name.isEmpty ? "iPad" : peer.name, systemImage: "ipad")
       Spacer()
       Button(model.trustedDevices.contains(where: { $0.deviceID == peer.deviceID }) ? "连接" : "配对") { coordinator.pairWiFi(peer) }
      }
     }
    }
    MacPairingConfirmation(model: model, coordinator: coordinator)
    if let note = model.lanNote { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    Button("打开本地网络权限设置…") { openPrivacyPane("Privacy_LocalNetwork") }
   }.card()
   VStack(alignment: .leading, spacing: 14) {
    Label("已配对设备", systemImage: "ipad.and.iphone").font(.headline)
    if model.trustedDevices.isEmpty {
     Text("还没有配对设备。首次连接时，在 Mac 和 iPad 两端确认即可。")
      .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    } else {
     ForEach(model.trustedDevices) { peer in
      HStack {
       Label(peer.name.isEmpty ? "iPad" : peer.name, systemImage: "ipad")
       Spacer()
       Button("忘记…", role: .destructive) { deviceToForget = peer }
      }
     }
    }
   }.card()
   VStack(alignment: .leading, spacing: 12) {
    Text("视频画质").font(.headline)
    videoSettingsEditor("USB", transport: .usb, settings: model.usbVideo)
    videoSettingsEditor("Wi-Fi", transport: .wifi, settings: model.wifiVideo)
    Text(model.videoSettingsNote).font(.caption).foregroundStyle(.secondary)
    Text("日常模式保留原生采集，最高目标 20 Mbps；各模式在拥塞时均会降级。USB 与 Wi-Fi 分别保存，下次连接生效。未完成验收前保留原默认档位。").font(.caption).foregroundStyle(.secondary)
   }.card()
   VStack(alignment: .leading, spacing: 9) {
    Text("书写与手势").font(.headline)
    Text("Pencil 与手指偏好在 iPad 设置里调整。PadInk 始终显示 Mac 主屏；绘图工具、颜色和橡皮使用当前 Mac 应用的控件。")
     .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    Button("查看支持的应用与操作") { navigation.selection = .help }
   }
  }
 }

 private func videoSettingsEditor(_ title: String, transport: TransportKind, settings: VideoSettings) -> some View {
  VStack(alignment: .leading) {
   Text(title).font(.subheadline.bold())
   Picker("模式", selection: Binding(get: { settings.mode }, set: { mode in
    guard mode != .saved else { return }
    coordinator.selectVideo(VideoSettings.daily(mode, codec: settings.codec), transport: transport)
   })) {
    Text("原档位（保留）").tag(VideoMode.legacy)
    Text("标准 · 8 Mbps").tag(VideoMode.standard)
    Text("高清 · 12 Mbps").tag(VideoMode.hd)
    Text("自动 · 最高 16 Mbps").tag(VideoMode.automatic)
    Text("高画质 · 最高 20 Mbps").tag(VideoMode.highQuality)
    if settings.mode == .saved { Text("已有自定义配置（保留）").tag(VideoMode.saved) }
   }
   Picker("编码", selection: Binding(get: { settings.codec }, set: { var s = settings; s.codec = $0; coordinator.selectVideo(s, transport: transport) })) {
    Text("H.264").tag(VideoCodec.h264); Text("HEVC").tag(VideoCodec.hevc)
   }
   Text("码率是目标预算，实际输出取决于内容；两种编码均需硬件解码确认。").font(.caption).foregroundStyle(.secondary)
   Button("恢复此前保存的配置") { coordinator.restoreSavedVideo(transport) }
   Button("恢复当前档位") { coordinator.selectVideo(.baseline, transport: transport) }
  }
 }

 private var helpPage: some View {
  Group {
   pageHeading("帮助", detail: "连接、书写与常见问题。")
   VStack(alignment: .leading, spacing: 15) {
    Text("开始使用").font(.headline)
    instructionRow("1.circle", title: "连接 iPad", detail: "首次建议用 USB。解锁 iPad，打开 PadInk，在两端确认配对。")
    instructionRow("2.circle", title: "在 Mac 应用里选好工具", detail: "PowerPoint 选择“绘图 › 笔”；GoodNotes 选择笔或橡皮。")
    instructionRow("3.circle", title: "拿起 Pencil 开始书写", detail: "手指点击，双指滚动或捏合缩放。文稿由 Mac 应用保存。")
    Button("返回连接") { navigation.selection = .connection }
   }.card()
   VStack(alignment: .leading, spacing: 15) {
    Text("常见问题").font(.headline)
    helpDisclosure("没有画面") {
     Text("检查 Mac 的屏幕录制权限。授权后如果系统要求，请退出并重新打开 PadInk。iPad 需要保持解锁，PadInk 需要在前台。")
     Button("检查 Mac 权限") { navigation.selection = .settings }
    }
    helpDisclosure("画面有了，操作没有反应") {
     Text("检查 Mac 的辅助功能权限，再确认目标应用当前选择了正确的工具。需要手指操作时，在 iPad 设置中打开“允许手指操作 Mac”。")
     Button("打开辅助功能设置…") { coordinator.openPrivacySettings(accessibility: true) }
    }
    helpDisclosure("应用缩放没有反应") {
     Text("缩放取决于当前应用可用的控件。不可用时，可使用应用自己的比例控件；PowerPoint 首次缩放可能需要自动化权限。")
     Button("打开 PowerPoint 自动化权限设置…") { openPrivacyPane("Privacy_Automation") }
     if model.connected { Button("恢复当前应用默认缩放") { coordinator.resetZoom() } }
    }
    helpDisclosure("连接中断或 Wi-Fi 连不上") {
     Text("保持两端 PadInk 打开，等待自动恢复。Wi-Fi 需要两端在同一网络，并允许本地网络访问；部分公司或校园网络会限制设备互连，可以先改用 USB。切换连接时请抬笔、抬指，画面恢复后继续。")
     Text("持续无法恢复时，先暂停连接，再重新连接。")
     Button("查看连接") { navigation.selection = .connection }
    }
    helpDisclosure("支持哪些 Mac 应用？") {
     supportRow("GoodNotes for Mac", detail: "书写、工具点击、滚动与连续捏合。使用 GoodNotes 自己的工具与颜色。")
     supportRow("PowerPoint", detail: "原生墨迹、点击、滚动与分档缩放。首次缩放可能需要自动化权限。")
     supportRow("预览", detail: "PDF 阅读、点击、滚动与缩放。批注先选择标注工具，保存后重新打开核对。")
     supportRow("Safari / Chrome", detail: "点击、拖动、双指滚动与分档缩放。能否书写取决于网页。")
    }
   }.card()
   VStack(alignment: .leading, spacing: 10) {
    Label("需要反馈问题？", systemImage: "stethoscope").font(.headline)
    Text("导出两端诊断，附上使用的应用、刚才的操作和两端版本。")
     .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    Button("打开诊断…") { navigation.selection = .diagnostics }
   }
  }
 }

 private var diagnosticsPage: some View {
  Group {
   pageHeading("诊断", detail: "问题发生后，在 Mac 和 iPad 两端各导出一次。")
   VStack(alignment: .leading, spacing: 14) {
    Label("导出诊断", systemImage: "square.and.arrow.up").font(.headline)
    Text("诊断只保存在本机，包含事件经过、性能、故障及构建与设备信息，不含输入坐标、压力、窗口标题、文稿名或画面。")
     .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    Button(model.exportingDiagnostics ? "正在导出…" : "导出并在 Finder 显示", systemImage: "square.and.arrow.up") { coordinator.exportDiagnostics() }
     .buttonStyle(.borderedProminent).disabled(model.exportingDiagnostics)
    if let message = model.exportMessage { Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    if let url = model.exportURL { Button("查看上次导出") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    Text("保存位置：文稿 / \(ProductIdentity.displayName) 诊断").font(.caption).foregroundStyle(.secondary)
   }.card()
   VStack(alignment: .leading, spacing: 12) {
    Text("当前状态").font(.headline)
    diagnosticRow("连接", value: model.status)
    diagnosticRow("传输", value: model.connected || model.phase == .connecting ? model.transport : "未连接")
    if !model.raster.isEmpty { diagnosticRow("画面", value: model.raster) }
    diagnosticRow("Mac", value: model.localVersion)
    diagnosticRow(model.connected ? "iPad" : "上次连接的 iPad", value: model.peerVersion ?? "尚未连接")
    if let note = model.usbNote { diagnosticRow("USB", value: note) }
    if let note = model.lanNote { diagnosticRow("Wi-Fi", value: note) }
    if let note = model.videoNote { diagnosticRow("画面状态", value: note) }
    if let note = model.zoomNote { diagnosticRow("应用缩放", value: note) }
    if let note = model.lastInputNote { diagnosticRow("输入提示", value: note) }
    if let note = model.previousSessionNote { diagnosticRow("上次运行", value: note) }
   }.card()
   VStack(alignment: .leading, spacing: 12) {
    Text("构建信息").font(.headline)
    buildDetails(model.buildIdentity)
   }.card()
   DisclosureGroup("收集系统崩溃报告") {
    Text("Mac：打开“控制台 › 崩溃报告”，保存同一时间的 PadInk 报告。\niPad：打开“设置 › 隐私与安全性 › 分析与改进 › 分析数据”，找到同一时间的 PadInk 条目并分享。报告由你选择提供，PadInk 不会自动收集。")
     .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
   }
  }
 }

 private var aboutPage: some View {
  Group {
   VStack(alignment: .leading, spacing: 16) {
    Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 80, height: 80)
    Text("PadInk").font(.largeTitle.weight(.semibold))
    Text("让 iPad 成为 Mac 的书写与触控界面。")
     .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    Text(model.localVersion).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
   }
   VStack(alignment: .leading, spacing: 12) {
    Text("安装与更新").font(.headline)
    Text(model.buildIdentity.installationGuidance).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    if model.buildIdentity.isDeveloperInstall {
     Text("开发者安装的续期与更新：连接 iPad，在源码目录运行“更新 PadInk.command”。请保留源码目录。")
      .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
   }.card()
   HStack(spacing: 16) {
    Button("使用帮助") { navigation.selection = .help }
    Button("诊断与构建信息") { navigation.selection = .diagnostics }
   }
  }
 }

 private func pageHeading(_ title: String, detail: String) -> some View {
  VStack(alignment: .leading, spacing: 6) {
   Text(title).font(.largeTitle.weight(.semibold))
   Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
 }

 private func transportCard(_ title: String, symbol: String, active: Bool, connecting: Bool, detail: String) -> some View {
  VStack(alignment: .leading, spacing: 10) {
   HStack {
    Label(title, systemImage: symbol).font(.headline)
    Spacer(minLength: 2)
    if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("当前连接") }
   }
   Text(active ? "当前连接" : model.paused ? "已暂停" : connecting ? "正在连接" : title == "USB" ? "插线自动连接" : "配对后自动连接")
    .font(.callout.weight(.medium)).foregroundStyle(active ? Color.primary : Color.secondary)
   Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }.frame(maxWidth: .infinity, alignment: .topLeading).card()
 }

 private func actionNote(_ note: String, symbol: String) -> some View {
  HStack(alignment: .top, spacing: 8) {
   Image(systemName: symbol).foregroundStyle(.orange)
   Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
  }
 }
}

private struct StatusSymbol: View {
 @ObservedObject var model: MacModel
 var body: some View {
  Image(systemName: model.presentationSymbol)
   .foregroundStyle(model.permissionsGranted && model.phase == .active ? Color.green : model.phase == .needsAttention || !model.permissionsGranted ? Color.orange : Color.accentColor)
   .accessibilityHidden(true)
 }
}

private struct TransportBadge: View {
 let transport: String
 var body: some View {
  Label(transport, systemImage: transport == "USB" ? "cable.connector" : "wifi")
   .font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4)
   .background(.quaternary, in: Capsule())
 }
}

private struct MacPairingConfirmation: View {
 @ObservedObject var model: MacModel
 let coordinator: MacCoordinator

 @ViewBuilder var body: some View {
  if let request = model.pairing {
   VStack(alignment: .leading, spacing: 12) {
    Label("允许连接这台 iPad？", systemImage: "cable.connector").font(.headline)
    Text(request.name.isEmpty ? "iPad" : request.name).font(.title3.weight(.medium))
    Text("确认是你连接的设备，在 Mac 和 iPad 两端都允许配对。")
     .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    HStack {
     Button("允许配对") { coordinator.confirmPairing(request, accepted: true) }.buttonStyle(.borderedProminent)
     Button("拒绝") { coordinator.confirmPairing(request, accepted: false) }
    }
   }.card()
  }
  if let prompt = model.lanPairing {
   VStack(alignment: .leading, spacing: 12) {
    Label("确认 Wi-Fi 配对", systemImage: "wifi").font(.headline)
    Text(prompt.name.isEmpty ? "iPad" : prompt.name).font(.callout.weight(.medium))
    Text(prompt.code).font(.system(.largeTitle, design: .monospaced).weight(.semibold)).textSelection(.enabled)
    Text("核对 iPad 上的六位配对码。完全相同后，在两端允许配对。")
     .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    HStack {
     Button("配对码一致，允许") { coordinator.confirmWiFiPairing(true) }.buttonStyle(.borderedProminent)
     Button("拒绝") { coordinator.confirmWiFiPairing(false) }
    }
   }.card()
  }
 }
}

private struct MacPermissionSection: View {
 @ObservedObject var model: MacModel
 let coordinator: MacCoordinator

 var body: some View {
  VStack(alignment: .leading, spacing: 14) {
   Label("Mac 权限", systemImage: "lock.shield").font(.headline)
   permissionRow("屏幕录制", granted: model.screenRecordingGranted, purpose: "将 Mac 主屏显示到 iPad。", accessibility: false)
   Divider()
   permissionRow("辅助功能", granted: model.accessibilityGranted, purpose: "让 Pencil 与手指操作 Mac 应用。", accessibility: true)
   if !model.permissionsGranted {
    Button("请求系统授权") { coordinator.requestPermissions() }.buttonStyle(.borderedProminent)
    Text("在系统设置里打开 PadInk 的开关。如系统提示，请退出并重新打开 PadInk；权限状态会自动更新。")
     .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
   }
  }.card()
 }

 private func permissionRow(_ title: String, granted: Bool, purpose: String, accessibility: Bool) -> some View {
  HStack(alignment: .top, spacing: 10) {
   Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
    .foregroundStyle(granted ? Color.green : Color.orange).padding(.top, 2)
   VStack(alignment: .leading, spacing: 4) {
    HStack(spacing: 7) {
     Text(title).font(.callout.weight(.medium))
     Text(granted ? "已允许" : "需要授权").font(.caption).foregroundStyle(.secondary)
    }
    Text(purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
   }
   Spacer(minLength: 5)
   if !granted { Button("打开设置…") { coordinator.openPrivacySettings(accessibility: accessibility) }.font(.callout) }
  }
 }
}

extension MacModel {
 var permissionsGranted: Bool { screenRecordingGranted && accessibilityGranted }
 var canPause: Bool { connected || pairing != nil || lanPairing != nil || (permissionsGranted && (phase == .waiting || phase == .connecting || phase == .recovering)) }
 var presentationTitle: String {
  if !permissionsGranted { return "完成 Mac 授权" }
  if pairing != nil || lanPairing != nil { return "等待确认配对" }
  return phase.title
 }
 var presentationSymbol: String {
  if !permissionsGranted { return "lock.shield" }
  if pairing != nil || lanPairing != nil { return "ipad.and.arrow.forward" }
  return phase.symbolName
 }
 var presentationDetail: String {
  if !permissionsGranted { return "允许屏幕录制和辅助功能后，就可以连接 iPad。" }
  if pairing != nil || lanPairing != nil { return "核对下方设备，并在两端允许配对。" }
  switch phase {
  case .active:
   if status.contains("画面降级") { return "网络较忙，已暂时降低画质以保持连接。" }
   return "\(peerName.isEmpty ? "iPad" : peerName) 正在显示 Mac 主屏。"
  case .waiting:
   let routine = ["等待 iPad 连接", "权限已就绪，等待 iPad 连接", "等待 iPad 连接：请解锁 iPad 并打开 PadInk"]
   return routine.contains(status) ? "解锁 iPad，打开 PadInk 并保持在前台。" : status
  case .connecting: return "正在通过 \(transport) 连接 iPad，请稍候。"
  case .waitingForVideo: return "已连接 \(peerName.isEmpty ? "iPad" : peerName)，等待画面显示。"
  case .recovering: return connected ? "画面正在恢复。请抬笔、抬指，恢复后继续操作。" : status
  case .paused: return status
  case .needsAttention: return videoNote ?? needsUpdate ?? status
  }
 }
 var actionableUpdateNote: String? { presentationDetail != needsUpdate ? needsUpdate : nil }
 var actionableVideoNote: String? { phase == .needsAttention && presentationDetail != videoNote ? videoNote : nil }
 var actionableInputNote: String? {
  guard let lastInputNote, lastInputNote != "前台应用切换，已安全结束当前笔画", lastInputNote != "已安全结束当前笔画" else { return nil }
  return lastInputNote
 }
 var actionableZoomNote: String? {
  guard let zoomNote, zoomNote != "已发送应用缩放命令", zoomNote != "已发送连续应用缩放" else { return nil }
  return zoomNote
 }
}

private extension View {
 func card() -> some View {
  padding(16).frame(maxWidth: .infinity, alignment: .leading)
   .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
   .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
 }
}

private func instructionRow(_ symbol: String, title: String, detail: String) -> some View {
 HStack(alignment: .top, spacing: 10) {
  Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 24).padding(.top, 1)
  VStack(alignment: .leading, spacing: 4) {
   Text(title).font(.callout.weight(.medium))
   Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }
 }
}

private func supportRow(_ name: String, detail: String) -> some View {
 VStack(alignment: .leading, spacing: 4) {
  Text(name).font(.callout.weight(.medium))
  Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
 }
}

private func helpDisclosure<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
 DisclosureGroup(title) {
  VStack(alignment: .leading, spacing: 10) { content() }
   .font(.callout).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
 }
}

private func diagnosticRow(_ title: String, value: String) -> some View {
 VStack(alignment: .leading, spacing: 4) {
  Text(title).font(.caption).foregroundStyle(.secondary)
  Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
 }
}

private func buildDetails(_ identity: BuildIdentity) -> some View {
 VStack(alignment: .leading, spacing: 10) {
  diagnosticRow("安装渠道", value: identity.distribution.rawValue)
  diagnosticRow("源码版本", value: identity.sourceRevision ?? "未嵌入")
  diagnosticRow("源码 SHA256", value: identity.sourceDigest ?? "未嵌入")
 }.font(.caption)
}

private func openPrivacyPane(_ pane: String) {
 if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
}
#endif
