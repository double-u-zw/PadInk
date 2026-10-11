import AppKit
import PadInkCore
import PadInkMacKit
import PadInkReplayKit
import PDFKit

// padink-replay: Mac-side real-application replay test (REWRITE_BRIEF §11.1).
// Injects recorded real Pencil strokes through the product PencilInputPipeline/PencilInjectionBackend
// into a fresh PowerPoint presentation, saves -> closes -> reopens it, and compares the saved native
// InkML with what was injected. Takes over the pointer: run locally, only while nobody uses the Mac.
//
//   padink-replay powerpoint [--event-source hid|private] [--strokes N] [--out DIR] [--yes] [--dry-run]
//   padink-replay preview [--strokes N] [--out DIR] [--yes]      (spike: Preview PDF markup)
//   padink-replay inspect FILE.pptx
//
// Stop at any time: create the STOP file printed at start, press Ctrl-C, or bring another app to the
// front. Every exit path releases the pen (up + proximity-out).

setvbuf(stdout, nil, _IONBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1] }
func flag(_ name: String) -> Bool { args.contains(name) }
var recordFailure: ((String) -> Void)?
func fail(_ message: String) -> Never { recordFailure?(message); FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8)); exit(1) }
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: inspect

if args.first == "inspect" {
 guard args.count >= 2 else { fail("用法：padink-replay inspect FILE.pptx") }
 let parts: [PPTXInk.Part]
 do { parts = try PPTXInk.parts(of: URL(fileURLWithPath: args[1])) }
 catch { fail("无法读取 pptx：\(error)") }
 print("ink parts: \(parts.count); traces: \(parts.reduce(0) { $0 + $1.traces.count }); points: \(parts.flatMap(\.traces).reduce(0) { $0 + $1.points.count })")
 exit(0)
}
if args.first == "persistence" {
 guard args.count == 3 else { fail("用法：padink-replay persistence BEFORE.pptx AFTER.pptx") }
 do {
  let r = InkPlacement.compare(try InkPlacement.read(URL(fileURLWithPath:args[1])), try InkPlacement.read(URL(fileURLWithPath:args[2])))
  print(String(decoding:try JSONEncoder().encode(r),as:UTF8.self)); exit(r.passed ? 0 : 2)
 } catch { fail("无法核验墨迹：\(error)") }
}
let target = args.first ?? ""
guard target == "powerpoint" || target == "preview" else { fail("用法：padink-replay powerpoint|preview [--event-source hid|private] [--strokes N] [--out DIR] [--yes] [--dry-run] | inspect FILE.pptx") }

// MARK: Setup

let dryRun = flag("--dry-run")
let sourceName = option("--event-source") ?? "hid"
let sourceState: CGEventSourceStateID
switch sourceName { case "hid": sourceState = .hidSystemState; case "private": sourceState = .privateState; default: fail("--event-source 只能是 hid 或 private") }
let fixtureURL = URL(fileURLWithPath: option("--fixture") ?? repo.appendingPathComponent("Fixtures/replay/baseline-real-strokes.json").path)
guard let fixture = try? JSONDecoder().decode(ReplayFixture.self, from: Data(contentsOf: fixtureURL)) else { fail("无法读取笔画 fixture：\(fixtureURL.path)") }
let strokeLimit = Int(option("--strokes") ?? "") ?? fixture.strokes.count
let strokes = Array(fixture.strokes.prefix(max(1, strokeLimit)))
let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
let out = URL(fileURLWithPath: option("--out") ?? repo.appendingPathComponent("build/evidence/replay-\(stamp)-\(sourceName)").path)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let stopFile = out.appendingPathComponent("STOP")
let commit = { let c = shell("/usr/bin/git", ["-C", repo.path, "rev-parse", "HEAD"]); return c.isEmpty ? "unknown" : c }()
let dirty = !shell("/usr/bin/git", ["-C", repo.path, "status", "--porcelain", "--", "Apps/Mac/Input", "Sources/PadInkCore/Input", "Sources/PadInkCore/Geometry"]).isEmpty
// Keep the test document alongside its evidence: macOS can deny this CLI access to another
// application's private container even when PowerPoint successfully saves there.
let document = URL(fileURLWithPath: option("--document") ?? out.appendingPathComponent("replay.pptx").path)

func shell(_ tool: String, _ arguments: [String]) -> String {
 let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = arguments; p.standardOutput = pipe; p.standardError = Pipe()
 try? p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
 return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
@discardableResult func powerpoint(_ body: String) -> String? {
 var error: NSDictionary?
 let result = NSAppleScript(source: "tell application id \"com.microsoft.Powerpoint\"\n\(body)\nend tell")?.executeAndReturnError(&error)
 if let error { FileHandle.standardError.write(Data("AppleScript: \(error)\n".utf8)); return nil }
 return result?.stringValue ?? ""
}
func frontmostIsPowerPoint() -> Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == (args.first == "preview" ? "com.apple.Preview" : "com.microsoft.Powerpoint") }
func powerPointWindow(_ bundle: String = "com.microsoft.Powerpoint") -> CGRect? {
 let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
 guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier else { return nil }
 let bounds = rows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
  .compactMap { ($0[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } }
 return ReplayWindow.documentBounds(in: bounds)
}

print("PadInk replay · event source \(sourceName) · \(strokes.count) strokes · commit \(commit.prefix(10))\(dirty ? " (critical paths dirty: results cannot become evidence)" : "")")
print("输出：\(out.path)")
print("紧急停止：touch \"\(stopFile.path)\"，或按 Ctrl-C，或切换到其他应用。")

let appID = target == "preview" ? "com.apple.Preview" : "com.microsoft.Powerpoint"
if !dryRun {
 guard AXIsProcessTrusted() else { fail("运行本工具的终端没有“辅助功能”权限：系统设置 › 隐私与安全性 › 辅助功能，打开当前终端应用后重试。") }
 guard CGPreflightPostEventAccess() else { fail("运行本工具的进程没有事件投递权限。请检查辅助功能授权后重试。") }
 guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) != nil else { fail("没有安装 \(appID)。") }
 if !flag("--yes") {
  print("\n本测试会接管鼠标约 \(Int(Double(strokes.count) * 1.4)) 秒。请确认没有人在使用这台 Mac，然后按回车继续（Ctrl-C 取消）。")
  _ = readLine()
 }
 if target == "powerpoint" {
  print("▶ 新建空白演示文稿")
  guard powerpoint("activate\nset p to make new presentation\nset s to make new slide at end of p with properties {layout:slide layout blank}\nsave p in (POSIX file \"\(document.path)\")") != nil else { fail("无法让 PowerPoint 新建并保存演示文稿（首次运行需在弹窗中允许终端控制 PowerPoint）。") }
  Thread.sleep(forTimeInterval: 2)
  print("\n请在 PowerPoint 中切换到 绘图 › 笔（任意颜色），把鼠标移出 PowerPoint 窗口，然后按回车。")
  print("（测试先写一笔校准并检查是否真的产生了墨迹；没有就停止。）")
  _ = readLine()
  _ = powerpoint("activate"); Thread.sleep(forTimeInterval: 1)
 }
}

// MARK: Injection

var stopRequested = false
signal(SIGINT) { _ in stopRequested = true }
var injected = [[CGPoint]](), current = [CGPoint]()
let diagnostics = Diagnostics()
let backend = PencilInjectionBackend(diagnostics: diagnostics, sourceState: sourceState, postEvent: { event in
 switch event.type {
 case .leftMouseDown: current = [event.location]
 case .leftMouseDragged: current.append(event.location)
 case .leftMouseUp: current.append(event.location); injected.append(current); current = []
 default: break
 }
 if !dryRun { event.post(tap: .cghidEventTap) }
})
let pipeline = PencilInputPipeline(backend: backend, diagnostics: diagnostics)
var rejects = [GestureNotice]()
pipeline.sendReject = { rejects.append($0) }
recordFailure = { message in
 try? diagnostics.export(to: out)
 let summary: [String: Any] = ["result": "INCOMPLETE", "failure": message, "commit": commit,
   "eventSource": sourceName, "injectedStrokes": injected.count,
   "rejects": rejects.map { "\($0.gestureID):\($0.reason)" }, "document": document.path]
 if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
  try? data.write(to: out.appendingPathComponent("incomplete.json"))
 }
}

let window = (dryRun || target == "preview") ? CGRect(x: 0, y: 0, width: 1470, height: 900) : (powerPointWindow() ?? { fail("找不到 PowerPoint 窗口。") }())
print("  回放窗口：\(window)")
// Slide canvas in Normal view lies right of the thumbnails and below the ribbon.
let region = CGRect(x: window.minX + window.width * 0.32, y: window.minY + window.height * 0.36, width: window.width * 0.46, height: window.height * 0.44)
let all = strokes.flatMap { $0 }
let bx = all.map(\.x).min()!, by = all.map(\.y).min()!, bw = max(0.001, all.map(\.x).max()! - bx), bh = max(0.001, all.map(\.y).max()! - by)
let scale = min(region.width / CGFloat(bw), region.height / CGFloat(bh))
// Map the fixture's bounding box into the region (aspect kept) through the product mapping:
// displayBounds is chosen so VideoGeometry.macPoint lands every sample inside `region`.
backend.displayBounds = CGRect(x: region.minX - CGFloat(bx) * scale, y: region.minY - CGFloat(by) * scale, width: scale, height: scale)
pipeline.attach(generation: 1)
pipeline.presentedGeometry(PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 2360, videoHeight: 1640))

func abortIfNeeded() {
 let reason: String? = stopRequested ? "Ctrl-C" : FileManager.default.fileExists(atPath: stopFile.path) ? "STOP 文件" : (!dryRun && !frontmostIsPowerPoint()) ? "前台应用不是 PowerPoint" : nil
 guard let reason else { return }
 pipeline.cancelAll(.targetChanged); pipeline.detach()
 fail("已停止（\(reason)），笔已安全抬起。未完成的结果不作为证据。")
}

func inject(_ stroke: [PencilSample]) {
 let batches = ReplayFixture.batches(stroke)
 let origin = MonotonicClock.now, first = stroke[0].timestamp
 for batch in batches {
  abortIfNeeded()
  let due = origin + (batch.last!.timestamp - first)
  while MonotonicClock.now < due { let gap = due - MonotonicClock.now; if gap > 200_000_000 { pipeline.keepalive(GestureKeepalive(gestureID: batch[0].stroke, lastSampleSequence: UInt32(batch[0].sequence)), stamp: ReceiveStamp(localTime: MonotonicClock.now), now: MonotonicClock.now) }; Thread.sleep(forTimeInterval: min(Double(gap) / 1e9, 0.1)) }
  let now = MonotonicClock.now
  guard let wire = try? PencilBatch(batch) else { fail("fixture 批次无效") }
  pipeline.pencil(wire, stamp: ReceiveStamp(localTime: now), now: now)
 }
}

func saveCloseReopen() -> (before: URL, after: URL)? {
 let before = out.appendingPathComponent("before-reopen.pptx"), after = out.appendingPathComponent("after-reopen.pptx")
 guard powerpoint("save active presentation") != nil else { return nil }
 Thread.sleep(forTimeInterval: 1.5)
 do { try FileManager.default.copyItem(at: document, to: before) }
 catch { fail("无法保存重开前的副本：\(error)") }
 guard powerpoint("close active presentation saving yes") != nil else { return nil }
 Thread.sleep(forTimeInterval: 1.5)
 guard powerpoint("open (POSIX file \"\(document.path)\")") != nil else { return nil }
 Thread.sleep(forTimeInterval: 3)
 guard powerpoint("save active presentation") != nil else { return nil }
 Thread.sleep(forTimeInterval: 1.5)
 do { try FileManager.default.copyItem(at: document, to: after) }
 catch { fail("无法保存重开后的副本：\(error)") }
 return (before, after)
}

if dryRun {
 for stroke in strokes { inject(stroke) }
 let report = StrokeComparison.compare(injected: injected, saved: injected)
 print("dry run: injected \(injected.count) strokes, \(injected.reduce(0) { $0 + $1.count }) points; rejects \(rejects.count); self-comparison max deviation \(report?.deviation.max ?? -1)")
 exit(rejects.isEmpty && injected.count == strokes.count ? 0 : 1)
}

if target == "preview" { runPreviewSpike() }

// Calibration: one stroke, then verify PowerPoint really created native ink.
print("▶ 校准笔画"); inject(strokes[0])
_ = powerpoint("save active presentation"); Thread.sleep(forTimeInterval: 1.5)
let calibration: Int
do { calibration = try PPTXInk.parts(of: document).count }
catch { pipeline.detach(); fail("无法读取校准文件（不代表没有墨迹）：\(error)。文件：\(document.path)") }
print("  管线投递 \(injected.count) 笔；拒绝 \(rejects.count) 笔")
guard calibration >= 1 else { pipeline.detach(); fail("可读取的校准文件中没有 PowerPoint 墨迹（绘图笔、投递位置或应用接收需排查）。") }
print("  校准产生 \(calibration) 个墨迹部件 ✓")

print("▶ 注入 \(strokes.count - 1) 笔（真实时序）")
for (i, stroke) in strokes.dropFirst().enumerated() {
 inject(stroke); Thread.sleep(forTimeInterval: 0.35)
 if (i + 1) % 10 == 0 { print("  \(i + 1)/\(strokes.count - 1)") }
}
pipeline.detach()

print("▶ 保存 → 关闭 → 重新打开 → 再保存")
guard let files = saveCloseReopen() else { fail("PowerPoint 保存/关闭/重新打开失败。") }
_ = powerpoint("close active presentation saving no")

// MARK: Analysis

guard let before = try? InkPlacement.read(files.before), let after = try? InkPlacement.read(files.after) else { fail("无法读取墨迹身份或位置变换；不作验收结论。") }
let persistence = InkPlacement.compare(before, after)
let persisted = persistence.passed
let saved = after.flatMap(\.traces)
guard let comparison = StrokeComparison.compare(injected: injected, saved: saved) else { fail("墨迹数量不足，无法比较。") }

struct Report: Codable {
 var date: String, commit: String, criticalPathsDirty: Bool, eventSource: String, powerPointVersion: String, macOS: String
 var fixture: String, strokes: Int, injectedStrokes: Int, savedInkParts: Int, savedInkPartsAfterReopen: Int, inkByteIdenticalAfterReopen: Bool, inkPlacementIdenticalAfterReopen: Bool
 var rejects: [String], comparison: StrokeComparison, result: String
}
let pptVersion = Bundle(url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Powerpoint")!)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
let pass = persisted && comparison.countsMatch && rejects.isEmpty && comparison.deformedStrokes.isEmpty
let result = pass ? "PASS" : (persisted && comparison.countsMatch ? "PARTIAL" : "FAIL")
let report = Report(date: stamp, commit: commit, criticalPathsDirty: dirty, eventSource: sourceName, powerPointVersion: pptVersion, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                    fixture: fixtureURL.lastPathComponent, strokes: strokes.count, injectedStrokes: injected.count, savedInkParts: before.count, savedInkPartsAfterReopen: after.count, inkByteIdenticalAfterReopen: persistence.bytesIdentical, inkPlacementIdenticalAfterReopen: persistence.placementIdentical,
                    rejects: rejects.map { "\($0.gestureID):\($0.reason)" }, comparison: comparison, result: result)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try? encoder.encode(report).write(to: out.appendingPathComponent("report.json"))
print("""

结果 \(result)
  注入 \(injected.count) 笔；保存 \(before.count) 个墨迹部件；重开后 \(after.count) 个；重开前后逐字节一致：\(persisted)
  端点误差 p50/p95/max：\(String(format: "%.2f/%.2f/%.2f", comparison.endpointError.p50, comparison.endpointError.p95, comparison.endpointError.max)) pt
  形状偏差 p50/p95/max：\(String(format: "%.2f/%.2f/%.2f", comparison.deviation.p50, comparison.deviation.p95, comparison.deviation.max)) pt；局部形变笔画：\(comparison.deformedStrokes)
  报告：\(out.appendingPathComponent("report.json").path)
源码提交：\(commit)；关键路径含未提交改动：\(dirty)。结果仅限本次回放，不代表真人验收。
""")
exit(pass ? 0 : 2)

// MARK: Preview spike (REWRITE_BRIEF §11.1: one spike, decides product scope, not a gate)

func runPreviewSpike() -> Never {
 let pdf = out.appendingPathComponent("spike.pdf")
 var box = CGRect(x: 0, y: 0, width: 842, height: 595)
 guard let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) else { fail("无法生成测试 PDF") }
 ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
 NSWorkspace.shared.open([pdf], withApplicationAt: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")!, configuration: NSWorkspace.OpenConfiguration())
 Thread.sleep(forTimeInterval: 3)
 print("\n请在“预览”中打开 标记 工具栏并选中 草图 或 绘图 工具，把鼠标移出窗口，然后按回车。")
 _ = readLine()
 _ = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Preview").first?.activate()
 Thread.sleep(forTimeInterval: 1)
 guard let w = powerPointWindow("com.apple.Preview") else { fail("找不到“预览”窗口。") }
 let r = CGRect(x: w.minX + w.width * 0.2, y: w.minY + w.height * 0.25, width: w.width * 0.6, height: w.height * 0.5)
 let pts = strokes.flatMap { $0 }; let x0 = pts.map(\.x).min()!, y0 = pts.map(\.y).min()!, sw = max(0.001, pts.map(\.x).max()! - x0), sh = max(0.001, pts.map(\.y).max()! - y0)
 let k = min(r.width / CGFloat(sw), r.height / CGFloat(sh))
 backend.displayBounds = CGRect(x: r.minX - CGFloat(x0) * k, y: r.minY - CGFloat(y0) * k, width: k, height: k)
 pipeline.attach(generation: 1); pipeline.presentedGeometry(PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 2360, videoHeight: 1640))
 for stroke in strokes { inject(stroke); Thread.sleep(forTimeInterval: 0.35) }
 pipeline.detach()
 var error: NSDictionary?
 NSAppleScript(source: "tell application id \"com.apple.Preview\" to save front document")?.executeAndReturnError(&error)
 Thread.sleep(forTimeInterval: 2)
 NSAppleScript(source: "tell application id \"com.apple.Preview\" to close front document saving yes")?.executeAndReturnError(&error)
 Thread.sleep(forTimeInterval: 2)
 let annotations = PDFDocument(url: pdf).map { d in (0..<d.pageCount).flatMap { d.page(at: $0)?.annotations ?? [] } } ?? []
 let kinds = Dictionary(grouping: annotations, by: { $0.type ?? "?" }).mapValues(\.count)
 let summary = "Preview spike: injected \(injected.count) strokes; saved annotations \(annotations.count) \(kinds); AppleScript error: \(error.map { "\($0)" } ?? "none")"
 try? summary.write(to: out.appendingPathComponent("preview-spike.txt"), atomically: true, encoding: .utf8)
 print(summary); print("PDF：\(pdf.path)（用“预览”重新打开以人工确认）")
 exit(annotations.isEmpty ? 2 : 0)
}
