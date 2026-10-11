#if os(macOS)
import Foundation
import PadInkCore

/// Executes InputOwnership decisions against the PencilInjectionBackend. Confined to the input
/// queue. Separated from MacCoordinator so the whole Mac Pencil path — wire batch to posted
/// CGEvents, rejections and the deadline timer — is testable with an event sink.
public final class PencilInputPipeline {
 public private(set) var ownership: InputOwnership
 public let backend: PencilInjectionBackend
 private let diagnostics: Diagnostics
 public private(set) var generation: UInt64 = 0
 /// INPUT_REJECTED to the iPad.
 public var sendReject: (GestureNotice) -> Void = { _ in }
 /// Arm (or cancel with nil) the one-shot timer; the owner calls `timer(now:)` when it fires.
 public var scheduleDeadline: (UInt64?) -> Void = { _ in }
 /// Called only after ownership admission, before the first physical Pencil down.
 public var onAcceptedBegin: () -> Void = {}
 public var onRelease: (CancelReason) -> Void = { _ in }

 public init(backend: PencilInjectionBackend, diagnostics: Diagnostics, policy: InputFreshnessPolicy = .initial) {
  self.backend = backend; self.diagnostics = diagnostics; ownership = InputOwnership(policy: policy)
 }

 /// A new attachment is ready.
 public func attach(generation g: UInt64) {
  execute(ownership.cancelAll(.sessionReplaced))
  // A fresh gatekeeper per attachment: nothing about earlier gestures may affect the new session.
  ownership = InputOwnership(policy: ownership.policy); generation = g; backend.reset(session: g)
 }
 /// The attachment ended (fault row 7): release, then refuse everything until the next attach.
 public func detach() { execute(ownership.cancelAll(.transportLost)); generation = 0; backend.reset(session: 0) }

 public func pencil(_ batch: PencilBatch, stamp: ReceiveStamp, now: UInt64) {
  diagnostics.performance.record(PerformanceEvent("input.receiveToPipeline", time: now, generation: generation, item: batch.gestureID, sample: batch.samples.first.map { UInt64($0.sequence) }, start: stamp.localTime, end: now, count: batch.samples.count))
  let commands = ownership.pencil(batch, stamp: stamp, now: now)
  if commands.contains(where: { if case .inject = $0 { return true }; return false }) {
   diagnostics.mark("input.receiveToInject", session: generation, item: batch.gestureID, value: Double(now >= stamp.localTime ? now - stamp.localTime : 0) / 1e6)
  }
  execute(commands)
 }
 public func keepalive(_ k: GestureKeepalive, stamp: ReceiveStamp, now: UInt64) { execute(ownership.keepalive(k, stamp: stamp, now: now)) }
 public func cancelFromPeer(_ n: GestureNotice) { execute(ownership.cancelFromPeer(n)) }
 public func presentedGeometry(_ g: PresentedGeometry) { execute(ownership.presentedGeometry(g)) }
 public func timer(now: UInt64) { execute(ownership.timer(now: now)) }
 public func cancelAll(_ reason: CancelReason) { execute(ownership.cancelAll(reason)) }

 private func execute(_ commands: [InputOwnership.Command]) {
  for command in commands {
   switch command {
   case .inject(let batch):
    if batch.batchFlags & 1 != 0 { onAcceptedBegin() }
    do { try backend.samples(batch.pencilSamples, session: generation); ownership.injected(batch) }
    catch {
     // Release first, unconditionally: whatever the bookkeeping says, nothing may stay pressed.
     backend.reset(session: generation)
     diagnostics.mark("input.backendRejected", session: generation, item: batch.gestureID)
     execute(ownership.backendRejected(gestureID: batch.gestureID))
    }
   case .release(let reason):
    backend.reset(session: generation)
    diagnostics.mark("input.cancel", session: generation, state: String(describing: reason), value: Double(reason.rawValue))
    if let row = reason.diagnosticFaultRow { diagnostics.fault(row: row, reason: String(describing: reason), generation: UInt32(truncatingIfNeeded: generation)) }
    onRelease(reason)
   case .reject(let notice):
    diagnostics.mark("input.rejected", session: generation, item: notice.gestureID, state: String(describing: notice.reason), value: Double(notice.reason.rawValue))
    sendReject(notice)
   }
  }
  // Invariant: the backend may hold a contact only while ownership tracks an active gesture.
  if ownership.active == nil, backend.active { backend.reset(session: generation); diagnostics.mark("input.invariantRelease", session: generation) }
  scheduleDeadline(ownership.nextDeadline)
 }
}
#endif
