import XCTest
import AppKit
import PadInkCore
@testable import PadInkMacKit

final class TwoFingerReleasePipelineTests: XCTestCase {
 private var context = ZoomActionContext(input: InputContext(attachmentID: UUID(), generation: 1), gestureID: 1 << 63, geometryGeneration: 1, targetRevision: 1)
 private func receive(_ z: ZoomController, _ event: TouchEvent) {
  if event.phase == .began { context = ZoomActionContext(input: context.input, gestureID: event.gestureID, geometryGeneration: event.geometryGeneration, targetRevision: 1) }
  z.receive(event, context: context)
 }

 private let pair = [FingerPoint(1, CGPoint(x: 100, y: 100)), FingerPoint(2, CGPoint(x: 200, y: 100))]
 private func event(_ a: TouchAction) -> TouchEvent {
  TouchEvent(gestureID: a.id, sequence: a.sequence, timestamp: a.timestamp, geometryGeneration: 1,
   kind: a.kind, phase: a.phase, x: 0.5, y: 0.5, dx: Float(a.delta.x / 500), dy: Float(a.delta.y / 500))
 }
 func testRealTwoFingerLiftPostsAppKitEndedScrollAndResetDoesNotCancelItAgain() {
  var events: [CGEvent] = [], f = GestureFSM(); f.touchEnabled = true
  let b = PointerInjectionBackend { events.append($0) }; b.displayBounds = CGRect(x: 0, y: 0, width: 500, height: 500)
  let p = TouchInputPipeline(backend: b, diagnostics: Diagnostics()); p.attach(); p.setEnabled(true)
  p.geometry(PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 500, videoHeight: 500))
  _ = f.update(pair, now: 0)
  var actions = f.update([FingerPoint(1, CGPoint(x: 100, y: 150)), FingerPoint(2, CGPoint(x: 200, y: 150))], now: 100_000_000)
  actions += f.update([FingerPoint(2, CGPoint(x: 200, y: 150))], now: 110_000_000)
  for a in actions { p.receive(event(a), stamp: .init(localTime: a.timestamp), now: a.timestamp, pencilActive: false) }
  XCTAssertEqual(events.compactMap { NSEvent(cgEvent: $0)?.phase }, [.began, .changed, .ended])
  XCTAssertNil(p.ownership.active); XCTAssertFalse(b.pressed)
  let count = events.count; p.cancel(.targetChanged); XCTAssertEqual(events.count, count)
 }
 private final class Context: ApplicationZoomContext {
  let family = ApplicationFamily.goodnotes
  var capabilities = ApplicationCapabilities(), commands: [ZoomCommand] = []
  func execute(_ command: ZoomCommand, permit: ZoomPermit) throws {
   guard permit.current else { throw ZoomFailure.cancelled }; commands.append(command)
  }
 }
 func testFirstPinchFingerLiftKeepsQueuedCommandWhileProbeFinishes() {
  let q = DispatchQueue(label: "release.zoom"), worker = DispatchQueue(label: "release.zoom.worker")
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), context = Context()
  let z = ZoomController(queue: q, worker: worker, probe: { _ in entered.signal(); release.wait(); return context })
  var f = GestureFSM(); f.touchEnabled = true; _ = f.update(pair, now: 0)
  let pinched = [FingerPoint(1, CGPoint(x: 90, y: 100)), FingerPoint(2, CGPoint(x: 210, y: 100))]
  let start = f.update(pinched, now: 100_000_000)
  func forward(_ actions: [TouchAction]) {
   for a in actions { var e = event(a); e.dx = Float(a.delta.x); self.receive(z, e) }
  }
  q.sync { forward(start) }; entered.wait()
  q.sync { forward(f.update([pinched[1]], now: 110_000_000)) }
  release.signal()
  for _ in 0..<4 { worker.sync {}; q.sync {} }
  XCTAssertEqual(context.commands, [.zoomIn])
 }
}
