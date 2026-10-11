import XCTest
import PadInkCore
@testable import PadInkMacKit
final class ZoomControllerTests: XCTestCase {
 private var context = ZoomActionContext(input: InputContext(attachmentID: UUID(), generation: 1), gestureID: 1 << 63, geometryGeneration: 1, targetRevision: 1)
 private func receive(_ z: ZoomController, _ event: TouchEvent) {
  if event.phase == .began { context = ZoomActionContext(input: context.input, gestureID: event.gestureID, geometryGeneration: event.geometryGeneration, targetRevision: 1) }
  z.receive(event, context: context)
 }

 private final class Context: ApplicationZoomContext {
  let family = ApplicationFamily.preview
  var capabilities = ApplicationCapabilities(), commands: [ZoomCommand] = []
  func execute(_ command: ZoomCommand, permit: ZoomPermit) throws { guard permit.current else { throw ZoomFailure.cancelled }; commands.append(command) }
 }
 private func event(_ phase: TouchPhase, _ delta: Float = 0) -> TouchEvent { TouchEvent(gestureID: 1 << 63, sequence: 1, timestamp: 0, geometryGeneration: 1, kind: .magnify, phase: phase, x: 0.5, y: 0.5, dx: delta) }
 func testQuickPinchCompletesOneQueuedPublicCommand() {
  let q = DispatchQueue(label: "zoom.test"), worker = DispatchQueue(label: "zoom.worker"), context = Context()
  let z = ZoomController(queue: q, worker: worker, probe: { _ in context })
  var submitted: [ZoomCommand] = []; z.onSubmitted = { submitted.append($0) }
  q.sync { self.receive(z, event(.began)); self.receive(z, event(.changed, 0.15)); self.receive(z, event(.ended)) }
  for _ in 0..<4 { worker.sync {}; q.sync {} }
  XCTAssertEqual(context.commands, [.zoomIn]); XCTAssertEqual(submitted, context.commands)
 }
 func testCancellationBeforeProbeReturnsNeverExecutesLateCommand() {
  let q = DispatchQueue(label: "zoom.test.cancel"), worker = DispatchQueue(label: "zoom.worker.cancel"), context = Context(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  let z = ZoomController(queue: q, worker: worker, probe: { _ in entered.signal(); release.wait(); return context })
  var submitted: [ZoomCommand] = []; z.onSubmitted = { submitted.append($0) }
  q.sync { self.receive(z, event(.began)); self.receive(z, event(.changed, 0.2)) }; entered.wait()
  q.sync { z.cancel() }; release.signal(); worker.sync {}; q.sync {}; worker.sync {}
  XCTAssertTrue(context.commands.isEmpty); XCTAssertTrue(submitted.isEmpty)
 }
 func testProbeFailureShowsFallbackAndNeverPostsInput() {
  let q = DispatchQueue(label: "zoom.test.failure"), worker = DispatchQueue(label: "zoom.worker.failure")
  let z = ZoomController(queue: q, worker: worker, probe: { _ in throw ZoomFailure.automationDenied }); var status = "", failure = ""
  z.onFailure = { failure = $0 }; z.onStatus = { status = $0 }; q.sync { z.resetZoom(context: context) }; worker.sync {}; q.sync {}
  XCTAssertTrue(status.contains("自动化")); XCTAssertEqual(failure, "automationDenied")
 }
 func testSlowPinchWithSmallCorrectionsSubmitsItsNetMovementAfterNormalEnd() {
  let q = DispatchQueue(label: "zoom.test.jitter"), worker = DispatchQueue(label: "zoom.worker.jitter"), context = Context()
  let z = ZoomController(queue: q, worker: worker, probe: { _ in context })
  q.sync {
   receive(z, event(.began))
   for _ in 0..<14 { self.receive(z, event(.changed, 0.01)); self.receive(z, event(.changed, -0.001)) }
   receive(z, event(.ended))
  }
  for _ in 0..<4 { worker.sync {}; q.sync {} }
  XCTAssertEqual(context.commands, [.zoomIn])
 }

}
