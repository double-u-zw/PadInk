#if canImport(UIKit)
import SwiftUI
import MetalKit
import PadInkCore

struct DisplaySurface: UIViewRepresentable {
 let coordinator: PadCoordinator
 @ObservedObject var model: PadModel
 func makeUIView(context: Context) -> PencilView {
  let view = PencilView(frame: .zero, device: coordinator.renderer?.device)
  view.colorPixelFormat = .bgra8Unorm; view.clearColor = MTLClearColorMake(0, 0, 0, 1); view.framebufferOnly = true; view.preferredFramesPerSecond = 60
  #if DEBUG
  if VideoReferenceCapture.enabled { view.framebufferOnly = false }
  #endif
  view.isMultipleTouchEnabled = true
  coordinator.bind(view); return view
 }
 func updateUIView(_ view: PencilView, context: Context) { view.isHidden = !model.connected; view.isPaused = !model.connected }
}

/// The control rail occupies its own space. Pencil and touch geometry always belong to the
/// actual Metal view below it, so permanent controls never cover any part of the Mac picture.
public struct PadScreen: View {
 let coordinator: PadCoordinator
 @ObservedObject var model: PadModel
 @State private var settings = false
 @State private var showNotice = false
 @State private var dismissedInputNote: String?
 @State private var initialSettingsPage: PadSettingsPage?
 private var previewMirror = false

 public init(coordinator: PadCoordinator) { self.coordinator = coordinator; model = coordinator.model }
 fileprivate init(coordinator: PadCoordinator, previewMirror: Bool, settingsPage: PadSettingsPage?, showSettings: Bool) {
  self.coordinator = coordinator; model = coordinator.model
  self.previewMirror = previewMirror; _initialSettingsPage = State(initialValue: settingsPage)
  _settings = State(initialValue: showSettings)
 }

 public var body: some View {
  VStack(spacing: 0) {
   controlRail
   Divider()
   GeometryReader { surface in
    ZStack {
     Color.black
     DisplaySurface(coordinator: coordinator, model: model)
     if !model.connected { waitingScreen(height: surface.size.height) }
#if DEBUG
     if previewMirror, model.connected {
      Label("界面预览 · 镜像区域", systemImage: "display")
       .font(.callout).foregroundStyle(.white.opacity(0.6)).allowsHitTesting(false)
     }
#endif
    }
    .onAppear { updateDrawable(surface.size) }
    .onChange(of: surface.size) { _, size in updateDrawable(size) }
   }
  }
  .background(Color(uiColor: .systemBackground))
  .ignoresSafeArea(edges: .bottom).statusBarHidden().persistentSystemOverlays(.hidden).tint(.teal)
  .sheet(item: activeSheet) { sheet in
   switch sheet {
   case .notice:
    noticeDetails
   case .settings:
    PadSettingsView(coordinator: coordinator, model: model, initialPage: initialSettingsPage)
   case .usb(let request):
    usbPairing(request).interactiveDismissDisabled()
   case .wifi(let prompt):
    wifiPairing(prompt).interactiveDismissDisabled()
   }
  }
  .onChange(of: model.pairing) { _, request in if request != nil { settings = false; showNotice = false } }
  .onChange(of: model.lanPairing) { _, prompt in if prompt != nil { settings = false; showNotice = false } }
  .onChange(of: model.lastInputNote) { _, _ in dismissedInputNote = nil }
 }

 private func updateDrawable(_ size: CGSize) {
  coordinator.setDrawable(CGSize(width: size.width * UIScreen.main.scale, height: size.height * UIScreen.main.scale))
 }

 private var controlRail: some View {
  HStack(spacing: 14) {
   HStack(spacing: 8) {
    if model.phase.isBusy { ProgressView().controlSize(.small) }
    else { Image(systemName: stateSymbol).foregroundStyle(stateColor) }
    Text(model.sessionActive ? "\(model.transport) · \(model.phase.title)" : model.phase.title)
     .font(.subheadline.weight(.medium)).lineLimit(1)
   }
   if model.sessionActive, !model.macName.isEmpty {
    Text(model.macName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
   }
   Spacer(minLength: 4)
   if !visibleNotices.isEmpty {
    Button { showNotice = true } label: {
     Image(systemName: noticeSymbol).foregroundStyle(noticeColor).frame(width: 36, height: 40)
    }
    .buttonStyle(.plain).accessibilityLabel("查看连接与输入提示")
   }
   if model.connected {
    Button { coordinator.setTouchEnabled(!model.touchEnabled) } label: {
     Label(model.touchEnabled ? "手指与 Pencil" : "仅 Pencil", systemImage: model.touchEnabled ? "hand.draw" : "pencil.tip")
      .font(.subheadline).lineLimit(1)
    }
    .buttonStyle(.borderless).accessibilityLabel("输入模式：\(model.touchEnabled ? "Pencil 和手指" : "仅 Pencil")。轻点切换")
    .accessibilityValue(model.touchEnabled ? "手指操作已开启" : "手指操作已关闭")
   }
   Button { initialSettingsPage = nil; settings = true } label: {
    Image(systemName: "gearshape").font(.body).frame(width: 44, height: 44)
   }
   .buttonStyle(.plain).disabled(pairingInProgress).accessibilityLabel("设置")
  }
  .padding(.leading, 20).padding(.trailing, 8).frame(height: 48)
 }

 private var pairingInProgress: Bool { model.pairing != nil || model.lanPairing != nil }
 private var stateColor: Color {
  switch model.phase {
  case .active: .green
  case .needsAttention, .recovering: .orange
  default: .secondary
  }
 }
 private var stateSymbol: String { model.phase == .active ? (model.transport == "USB" ? "cable.connector" : "wifi") : model.phase.symbolName }
 private var visibleNotices: [String] {
  var notes = [String]()
  if let note = model.transportNotice { notes.append(note) }
  if let note = model.usbNote { notes.append(note) }
  if model.connected, let note = model.videoNote { notes.append(note) }
  if let note = model.lastInputNote, note != dismissedInputNote { notes.append(note) }
  return notes
 }
 private var noticeSymbol: String {
  let hasInputNotice = model.lastInputNote != nil && model.lastInputNote != dismissedInputNote
  return hasInputNotice || (model.connected && model.videoNote != nil) || model.usbNote != nil ? "exclamationmark.circle" : "info.circle"
 }
 private var noticeColor: Color { noticeSymbol == "info.circle" ? .secondary : .orange }

 private func waitingScreen(height: CGFloat) -> some View {
  ScrollView {
   VStack(alignment: .leading, spacing: 28) {
    HStack(spacing: 16) {
     Image(systemName: "pencil.tip.crop.circle").font(.system(size: 52, weight: .light)).foregroundStyle(.tint)
     VStack(alignment: .leading, spacing: 5) {
      Text("PadInk").font(.largeTitle.bold())
      Text("让 iPad 成为 Mac 的书写与触控屏").font(.callout).foregroundStyle(.secondary)
     }
    }
    if model.phase == .waiting, !model.sessionActive {
     VStack(alignment: .leading, spacing: 18) {
      Text(model.trustedDevices.isEmpty ? "用 USB 开始" : "等待 Mac 连接").font(.title2.weight(.semibold))
      if model.trustedDevices.isEmpty { PadConnectionSteps() }
      else {
       Text("打开 Mac 上的 PadInk，并保持 iPad 上的此页面打开。插上 USB 数据线，或连接到已配对的 Wi-Fi，画面会自动出现。")
        .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
       if model.status != "等待 Mac 连接" { Text(model.status).font(.callout).foregroundStyle(.secondary) }
      }
     }
    } else {
     VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
       if model.phase.isBusy { ProgressView() }
       else { Image(systemName: model.phase.symbolName).foregroundStyle(stateColor) }
       Text(model.phase.title).font(.title2.weight(.semibold))
      }
      Text(model.status).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let note = model.videoNote, note != model.status { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
      if model.sessionActive { Text("请保持两端 PadInk 打开。画面出现后即可继续使用。").font(.callout).foregroundStyle(.secondary) }
     }
    }
    if let note = model.usbNote { Label(note, systemImage: "cable.connector").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
    HStack(spacing: 18) {
     if !model.sessionActive {
      Button { coordinator.beginWiFiPairing() } label: { Label("配对 Wi-Fi", systemImage: "wifi") }.buttonStyle(.bordered)
     }
     Button { initialSettingsPage = .help; settings = true } label: { Label("连接帮助", systemImage: "questionmark.circle") }.buttonStyle(.borderless)
    }
    if !model.sessionActive {
     Text("USB 会自动优先使用；拔线后会尝试恢复已配对的 Wi-Fi。").font(.footnote).foregroundStyle(.secondary)
     if let note = model.lanNote { Text(note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
   }
   .frame(maxWidth: 600, alignment: .leading).padding(.horizontal, 36).padding(.vertical, 36)
   .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
  }.background(Color(uiColor: .systemBackground))
 }

 private var noticeDetails: some View {
  NavigationStack {
   List {
    ForEach(visibleNotices, id: \.self) { note in Text(note).font(.body).fixedSize(horizontal: false, vertical: true) }
   }
   .navigationTitle("使用提示").navigationBarTitleDisplayMode(.inline)
   .toolbar { ToolbarItem(placement: .confirmationAction) {
    Button("完成") {
     dismissedInputNote = model.lastInputNote
     showNotice = false
    }
   } }
  }.tint(.teal).presentationDetents([.medium, .large])
 }

 private var activeSheet: Binding<PadSheet?> {
  Binding(get: {
   if let request = model.pairing { return .usb(request) }
   if let prompt = model.lanPairing { return .wifi(prompt) }
   if settings { return .settings }
   return showNotice ? .notice : nil
  }, set: { sheet in if sheet == nil { settings = false; showNotice = false } })
 }

 private func usbPairing(_ request: PairingRequest) -> some View {
  PadPairingView(symbol: "cable.connector", title: "允许这台 Mac 连接？", name: request.name, code: nil,
   detail: "确认这是你用数据线连接的 Mac，并在两端分别允许配对。", action: "允许配对",
   accept: { coordinator.confirmPairing(request, accepted: true) }, reject: { coordinator.confirmPairing(request, accepted: false) })
 }
 private func wifiPairing(_ prompt: LANPairingPrompt) -> some View {
  PadPairingView(symbol: "wifi", title: "核对 Wi-Fi 配对码", name: prompt.name, code: prompt.code,
   detail: "Mac 上也应显示这六位数字。完全一致时，在两端分别确认。", action: "配对码一致，允许连接",
   accept: { coordinator.confirmWiFiPairing(true) }, reject: { coordinator.confirmWiFiPairing(false) })
 }
}

private enum PadSheet: Identifiable {
 case settings, notice, usb(PairingRequest), wifi(LANPairingPrompt)
 var id: String {
  switch self {
  case .settings: "settings"
  case .notice: "notice"
  case .usb(let request): "usb-\(request.id)"
  case .wifi(let prompt): "wifi-\(prompt.code)"
  }
 }
}

private struct PadPairingView: View {
 let symbol: String, title: String, name: String, code: String?, detail: String, action: String
 let accept: () -> Void, reject: () -> Void
 var body: some View {
  VStack(spacing: 0) {
   ScrollView {
    VStack(spacing: 16) {
     Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(.tint)
     Text(title).font(.title2.bold())
     Text(name.isEmpty ? "Mac" : name).font(.headline).textSelection(.enabled)
     if let code {
      Text(code).font(.system(size: 40, weight: .semibold, design: .monospaced)).tracking(5)
       .accessibilityLabel("配对码 \(code.map { String($0) }.joined(separator: " "))")
     }
     Text(detail).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
     Text("配对后，这台 Mac 可以向 iPad 显示画面，并接收 Pencil 和手指操作。")
      .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }.padding(28).frame(maxWidth: 480).frame(maxWidth: .infinity)
   }
   // Keep the decision visible even on iPad mini or with a larger text size.
   VStack(spacing: 14) {
    Button(action, action: accept).buttonStyle(.borderedProminent).controlSize(.large)
    Button("拒绝连接", role: .cancel, action: reject).buttonStyle(.borderless)
   }.padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 24)
  }
  .tint(.teal).presentationDetents([.large]).presentationDragIndicator(.hidden)
 }
}

private struct PadConnectionSteps: View {
 var body: some View {
  VStack(alignment: .leading, spacing: 18) {
   step("1", title: "打开 Mac 上的 PadInk", detail: "按提示允许屏幕录制和辅助功能。")
   step("2", title: "用数据线连接并解锁 iPad", detail: "系统询问时，选择“信任此电脑”。")
   step("3", title: "在两端允许配对", detail: "出现 Mac 画面后，就可以用 Pencil 书写。")
  }
 }
 private func step(_ number: String, title: String, detail: String) -> some View {
  HStack(alignment: .top, spacing: 12) {
   Text(number).font(.callout.weight(.semibold)).foregroundStyle(.tint).frame(width: 26, height: 26)
    .background(Color.teal.opacity(0.1), in: Circle())
   VStack(alignment: .leading, spacing: 4) {
    Text(title).font(.body.weight(.medium))
    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
   }
  }
 }
}

private enum PadSettingsPage: String, Hashable {
 case connection, help, diagnostics, about
 var title: String {
  switch self {
  case .connection: "连接与设备"
  case .help: "使用帮助"
  case .diagnostics: "诊断"
  case .about: "关于 PadInk"
  }
 }
}

private struct PadSettingsView: View {
 let coordinator: PadCoordinator
 @ObservedObject var model: PadModel
 @Environment(\.dismiss) private var dismiss
 @State private var path: [PadSettingsPage]
 init(coordinator: PadCoordinator, model: PadModel, initialPage: PadSettingsPage?) {
  self.coordinator = coordinator; self.model = model
  _path = State(initialValue: initialPage.map { [$0] } ?? [])
 }
 var body: some View {
  NavigationStack(path: $path) {
   Form {
    Section("输入") {
     Toggle("允许手指操作 Mac", isOn: Binding(get: { model.touchEnabled }, set: { coordinator.setTouchEnabled($0) }))
     Text(model.touchEnabled ? "单指点击、双击和拖动；双指滚动和捏合缩放。Pencil 优先。" : "仅 Pencil 模式：手指不会操作 Mac。")
      .font(.callout).foregroundStyle(.secondary)
    }
    Section("连接") {
     NavigationLink(value: PadSettingsPage.connection) {
      HStack {
       Label("连接与设备", systemImage: "ipad.and.arrow.forward")
       Spacer()
       Text(model.sessionActive ? "\(model.transport) · \(model.phase.title)" : model.phase.title).foregroundStyle(.secondary).font(.callout)
      }
     }
    }
    Section {
     NavigationLink(value: PadSettingsPage.help) { Label("使用帮助", systemImage: "questionmark.circle") }
     NavigationLink(value: PadSettingsPage.diagnostics) { Label("诊断", systemImage: "stethoscope") }
     NavigationLink(value: PadSettingsPage.about) { Label("关于 PadInk", systemImage: "info.circle") }
    }
   }
   .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
   .navigationDestination(for: PadSettingsPage.self) { page in
    Group {
     switch page {
     case .connection: PadConnectionSettings(coordinator: coordinator, model: model)
     case .help: PadHelpView()
     case .diagnostics: PadDiagnosticsView(coordinator: coordinator, model: model)
     case .about: PadAboutView(model: model)
     }
    }.navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
     .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
   }
   .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
  }.tint(.teal)
 }
}

private struct PadConnectionSettings: View {
 let coordinator: PadCoordinator
 @ObservedObject var model: PadModel
 @State private var forgetRequest: PairingRequest?
 var body: some View {
  Form {
   Section("当前连接") {
    LabeledContent("状态", value: model.phase.title)
    if model.sessionActive {
     LabeledContent("Mac", value: model.macName.isEmpty ? "Mac" : model.macName)
     LabeledContent("连接方式", value: model.transport)
    }
    if model.phase != .active { Text(model.status).font(.callout).foregroundStyle(.secondary) }
    if let note = model.videoNote { Label(note, systemImage: "display.trianglebadge.exclamationmark").font(.callout).foregroundStyle(.orange) }
    if let note = model.usbNote { Label(note, systemImage: "cable.connector").font(.callout).foregroundStyle(.orange) }
    Text("USB 会自动优先使用；拔线后会尝试恢复已配对的 Wi-Fi。切换完成后，请重新落笔。").font(.callout).foregroundStyle(.secondary)
   }
   Section("Wi-Fi") {
    Button { coordinator.beginWiFiPairing() } label: { Label("配对 Wi-Fi", systemImage: "wifi") }
    Text("两端连接同一网络。在 Mac 的“设置 › Wi-Fi 连接”中选择这台 iPad，核对配对码，并在两端确认。配对窗口持续 2 分钟。")
     .font(.callout).foregroundStyle(.secondary)
    if let note = model.lanNote { Text(note).font(.callout).foregroundStyle(.secondary) }
   }
   Section("已配对的 Mac") {
    if model.trustedDevices.isEmpty { Text("尚未配对 Mac").foregroundStyle(.secondary) }
    ForEach(model.trustedDevices) { peer in
     HStack {
      Label(peer.name.isEmpty ? "Mac" : peer.name, systemImage: "laptopcomputer")
      Spacer()
      Button("忘记", role: .destructive) { forgetRequest = peer }
     }
    }
    Button("允许重新配对") { coordinator.allowPairing() }
    Text("曾拒绝配对或忘记设备后，可允许重新配对，再在 Mac 点“重新连接”。").font(.callout).foregroundStyle(.secondary)
   }
  }
  .alert(item: $forgetRequest) { peer in
   Alert(title: Text("忘记 \(peer.name.isEmpty ? "这台 Mac" : peer.name)？"),
    message: Text("这台 Mac 将不能自动连接；当前连接也会断开。之后需要重新配对。"),
    primaryButton: .destructive(Text("忘记设备")) { coordinator.forgetDevice(peer) }, secondaryButton: .cancel(Text("取消")))
  }
 }
}

private struct PadHelpView: View {
 var body: some View {
  Form {
   Section("首次连接") { PadConnectionSteps().padding(.vertical, 6) }
   Section("书写与触控") {
    guidance("Pencil 书写", symbol: "pencil.tip", detail: "先在 Mac 应用中选择笔、橡皮或批注工具，再在 iPad 上操作。文档由 Mac 应用保存。")
    guidance("手指操作", symbol: "hand.draw", detail: "单指点击、双击和拖动；双指滚动和捏合缩放。在顶部或设置中可切换为仅 Pencil 模式。")
   }
   Section("连接帮助") {
    guidance("连接成功，但没有画面", symbol: "display", detail: "检查 Mac 的屏幕录制权限。授权后仍无画面时，请退出并重新打开 Mac 上的 PadInk。")
    guidance("Wi-Fi 找不到设备", symbol: "wifi", detail: "确认两端在同一网络，并允许 PadInk 访问本地网络。公司或校园网络可能限制设备互连，可先使用 USB。")
    Button("打开 iPad 系统设置") {
     guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
     UIApplication.shared.open(url)
    }
   }
   Section("常用 Mac 应用") {
    guidance("GoodNotes", symbol: "pencil.and.scribble", detail: "在 Mac 上打开文档并选择书写工具；支持双指滚动和连续捏合缩放。")
    guidance("PowerPoint", symbol: "rectangle.on.rectangle", detail: "选择“绘图”中的笔；首次缩放时，Mac 可能询问自动化权限。")
    guidance("预览", symbol: "doc.richtext", detail: "选择批注或绘图工具后操作 PDF。")
    guidance("Safari 与 Chrome", symbol: "globe", detail: "支持点击、拖动、滚动和网页缩放。书写需要网页自身提供绘图工具。")
    Text("缩放能力由当前 Mac 应用决定；不可用时，可使用应用自己的缩放控件。").font(.callout).foregroundStyle(.secondary)
   }
   Section {
    NavigationLink(value: PadSettingsPage.diagnostics) { Label("问题仍未解决？查看诊断", systemImage: "stethoscope") }
   }
  }
 }
 private func guidance(_ title: String, symbol: String, detail: String) -> some View {
  VStack(alignment: .leading, spacing: 5) {
   Label(title, systemImage: symbol).font(.body.weight(.medium))
   Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }.padding(.vertical, 4)
 }
}

private struct PadDiagnosticsView: View {
 let coordinator: PadCoordinator
 @ObservedObject var model: PadModel
 var body: some View {
  Form {
   Section("诊断文件") {
    if let note = model.previousSessionNote { Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
    Button { coordinator.exportDiagnostics() } label: {
     HStack {
      Label(model.exportingDiagnostics ? "正在生成…" : "生成 iPad 诊断", systemImage: "doc.badge.gearshape")
      if model.exportingDiagnostics { Spacer(); ProgressView() }
     }
    }.disabled(model.exportingDiagnostics)
    if let note = model.exportNote { Text(note).font(.callout).textSelection(.enabled) }
    if let url = model.exportURL { ShareLink(item: url) { Label("分享诊断文件", systemImage: "square.and.arrow.up") } }
    Text("请同时在 Mac 的“诊断”中导出文件，并附上问题发生的大致时间。").font(.callout).foregroundStyle(.secondary)
   }
   Section("隐私") {
    Text("诊断只保存在本机，记录连接、性能、故障和构建信息，不包含触控坐标、压力、文档名、窗口标题或画面。由你决定是否分享。")
     .font(.callout).foregroundStyle(.secondary)
   }
   Section("闪退报告") {
    Text("打开 iPad 设置 › 隐私与安全性 › 分析与改进 › 分析数据，找到问题发生时的 PadInk 条目并分享。Mac 可在“控制台”App 的“崩溃报告”中找到同一时间的报告。")
     .font(.callout).foregroundStyle(.secondary)
    Link("Apple 崩溃报告说明", destination: URL(string: "https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs")!)
   }
  }
 }
}

private struct PadAboutView: View {
 @ObservedObject var model: PadModel
 var body: some View {
  Form {
   Section {
    VStack(spacing: 10) {
     Image(systemName: "pencil.tip.crop.circle").font(.system(size: 48, weight: .light)).foregroundStyle(.tint)
     Text("PadInk").font(.title2.bold())
     Text("让 iPad 成为 Mac 的书写与触控屏").font(.callout).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity).padding(.vertical, 18)
    LabeledContent("iPad 版本", value: model.localVersion).textSelection(.enabled)
    if let peer = model.peerVersion { LabeledContent(model.sessionActive ? "Mac 版本" : "上次连接的 Mac 版本", value: peer).textSelection(.enabled) }
   }
   Section("安装与更新") {
    if model.buildIdentity.isDeveloperInstall, let reminder = model.signingReminder { Label(reminder, systemImage: "calendar.badge.exclamationmark").foregroundStyle(.orange) }
    Text(model.buildIdentity.installationGuidance).font(.callout).foregroundStyle(.secondary)
   }
   Section {
    DisclosureGroup("构建详情") {
     LabeledContent("安装渠道", value: model.buildIdentity.distribution.rawValue)
     Text("源码版本：\(model.buildIdentity.sourceRevision ?? "未嵌入")").font(.caption.monospaced()).textSelection(.enabled)
     Text("源码 SHA256：\(model.buildIdentity.sourceDigest ?? "未嵌入")").font(.caption.monospaced()).textSelection(.enabled)
    }
   }
  }
 }
}

#if DEBUG
/// Local screenshot harness. Uses the real views and model without creating a network session.
public struct PadUIFixtureScreen: View {
 private let coordinator: PadCoordinator
 private let page: String
 public init(coordinator: PadCoordinator, page: String) { self.coordinator = coordinator; self.page = page }
 public var body: some View {
  PadScreen(coordinator: coordinator, previewMirror: true, settingsPage: PadSettingsPage(rawValue: page),
   showSettings: page == "settings" || PadSettingsPage(rawValue: page) != nil)
 }
}
#endif
#endif
