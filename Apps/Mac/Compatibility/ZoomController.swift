#if os(macOS)
import Foundation
import PadInkCore

/// Immutable reception identity. A reset has no contact, but has its own unique action ID.
struct ZoomActionContext {
 let input: InputContext, gestureID: UInt64?, geometryGeneration: UInt32, targetRevision: UInt64
 let actionID: UUID
 let target: ZoomTargetSnapshot?
 init(input: InputContext, gestureID: UInt64?, geometryGeneration: UInt32, targetRevision: UInt64, target: ZoomTargetSnapshot? = nil) {
  self.input = input; self.gestureID = gestureID; self.geometryGeneration = geometryGeneration
  self.targetRevision = targetRevision; self.target = target; actionID = UUID()
 }
}

/// One bounded, signed pixel demand. Subpixel travel survives changed, but never ended.
/// Gain is an initial GoodNotes experience parameter, not a claim of native 1:1 magnification.
private struct PixelZoomMotion {
 static let interval: UInt64 = 16_666_667, freshness: UInt64 = 100_000_000
 static let pixelsPerLogUnit = 160.0, limit = 64.0
 private var pending = 0.0, direction = 0.0, reverseTravel = 0.0
 private var addedAt: UInt64?, submitted: UInt64?
 mutating func expire(now: UInt64) {
  if let addedAt, now < addedAt || now - addedAt > Self.freshness {
   pending = 0; reverseTravel = 0; self.addedAt = nil
  }
 }
 func reverses(_ delta: Double) -> Bool {
  delta.isFinite && abs(delta) <= 1 && direction * delta < 0 && reverseTravel + abs(delta * Self.pixelsPerLogUnit) >= 1
 }
 func reversed() -> PixelZoomMotion {
  var next = PixelZoomMotion(); next.submitted = submitted
  // Carry confirmed opposite travel, never the old pending whole/fractional demand.
  next.direction = direction; next.reverseTravel = reverseTravel; return next
 }
 mutating func add(_ delta: Double, now: UInt64) {
  guard delta.isFinite, abs(delta) <= 1, delta != 0 else { return }
  expire(now: now)
  if direction * delta < 0 {
   reverseTravel += abs(delta * Self.pixelsPerLogUnit)
   if reverseTravel >= 1 {
    pending = (delta > 0 ? -1 : 1) * reverseTravel; direction = delta > 0 ? 1 : -1; reverseTravel = 0
   } else { pending -= delta * Self.pixelsPerLogUnit } // below one pixel: net correction, not a new direction
  } else {
   reverseTravel = 0; direction = delta > 0 ? 1 : -1; pending -= delta * Self.pixelsPerLogUnit
  }
  pending = max(-Self.limit, min(Self.limit, pending)); addedAt = now
 }
 private var hasPixel: Bool { abs(pending) >= 1 }
 func delay(now: UInt64) -> UInt64? {
  guard hasPixel else { return nil }
  guard let submitted else { return 0 }
  guard now >= submitted else { return Self.interval }
  return now - submitted >= Self.interval ? 0 : Self.interval - (now - submitted)
 }
 mutating func take(now: UInt64) -> (delta: Int32, expiresAt: UInt64)? {
  expire(now: now)
  guard let addedAt, now >= addedAt, now - addedAt <= Self.freshness else { pending = 0; return nil }
  guard delay(now: now) == 0 else { return nil }
  let pixel = Int32(pending.rounded(.towardZero)); pending -= Double(pixel); submitted = now
  return (pixel, addedAt + Self.freshness)
 }
}

/// All scheduling state lives on the input queue. Cancellation invalidates an action, NOT its
/// physical worker slot. At most one job and one current action exist, even through replacement.
final class ZoomController {
 private final class Action {
  let permit: ZoomPermit
  var target: ApplicationZoomContext?, steps = DiscreteZoom(), pixels = PixelZoomMotion()
  var scheduled = false, pixelStatusShown = false, terminal: Bool, resetting: Bool
  var cancelTimer: (() -> Void)?
  init(_ context: ZoomActionContext, reset: Bool) { permit = ZoomPermit(context: context); terminal = reset; resetting = reset }
 }
 private struct Job { let id: UUID, action: Action }
 private let enqueueWorker: (@escaping () -> Void) -> Void, enqueueCompletion: (@escaping () -> Void) -> Void
 private let schedule: (UInt64, @escaping () -> Void) -> (() -> Void)
 private let probe: (ZoomPermit) throws -> ApplicationZoomContext, clock: () -> UInt64
 private var action: Action?, job: Job?
 var onFailure: (String) -> Void = { _ in }
 var onSubmitted: (ZoomCommand) -> Void = { _ in }
 var onStatus: (String) -> Void = { _ in }, onStrategy: (String) -> Void = { _ in }
 var onStage: (ZoomActionContext, UUID?, String, UInt64) -> Void = { _, _, _, _ in }
 convenience init(queue: DispatchQueue, worker: DispatchQueue = DispatchQueue(label: "pnk2.zoom.commands", qos: .userInitiated), clock: @escaping () -> UInt64 = { MonotonicClock.now }, probe: @escaping (ZoomPermit) throws -> ApplicationZoomContext = { try ApplicationZoomTarget.probe($0) }) {
  self.init(clock: clock, enqueueWorker: { action in worker.async { action() } }, enqueueCompletion: { action in queue.async { action() } },
   schedule: { delay, action in
    let item = DispatchWorkItem(block: action)
    queue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay)), execute: item)
    return { item.cancel() }
   }, probe: probe)
 }
 /// Caller-owned executors/virtual time exercise the same product control flow.
 init(clock: @escaping () -> UInt64, enqueueWorker: @escaping (@escaping () -> Void) -> Void, enqueueCompletion: @escaping (@escaping () -> Void) -> Void,
   schedule: @escaping (UInt64, @escaping () -> Void) -> (() -> Void), probe: @escaping (ZoomPermit) throws -> ApplicationZoomContext) {
  self.clock = clock; self.enqueueWorker = enqueueWorker; self.enqueueCompletion = enqueueCompletion; self.schedule = schedule; self.probe = probe
 }
 func receive(_ event: TouchEvent, context: ZoomActionContext) {
  if event.phase == .began { begin(context, reset: false); return }
  guard let a = action, a.permit.context?.actionID == context.actionID else { return }
  switch event.phase {
  case .changed:
   guard !a.terminal else { return }
   let delta = Double(event.dx), now = clock()
   // Expired subpixel travel cannot help a new sample trigger direction replacement.
   a.pixels.expire(now: now)
   if a.target?.supportsContinuousZoom == true, a.pixels.reverses(delta) {
    // Revoke even an old-direction worker waiting before claim. Keep its physical slot;
    // replacement uses the same immutable input/action identity and validated adapter.
    let next = Action(context, reset: false); next.target = a.target; next.pixels = a.pixels.reversed()
    next.pixelStatusShown = a.pixelStatusShown
    a.permit.cancel(); a.cancelTimer?(); action = next
    next.pixels.add(delta, now: now)
   } else { a.steps.add(logDelta: delta); a.pixels.add(delta, now: now) }
   pump()
  case .ended:
   if a.target?.supportsContinuousZoom == true { cancel() }
   else { a.terminal = true; pump() }
  case .cancelled: cancel(context: context)
  case .began: break
  }
 }
 func resetZoom(context: ZoomActionContext) { begin(context, reset: true) }
 func cancel(context: ZoomActionContext) {
  guard action?.permit.context?.actionID == context.actionID else { return }; cancel()
 }
 func invalidate(input: InputContext, gestureID: UInt64? = nil, touchOnly: Bool = false) {
  guard let c = action?.permit.context, c.input == input,
    gestureID.map({ $0 == c.gestureID }) ?? true, !touchOnly || c.gestureID != nil else { return }; cancel()
 }
 func geometry(_ next: PresentedGeometry, input: InputContext) {
  guard let c = action?.permit.context, c.input == input, !next.ready || next.generation != c.geometryGeneration else { return }; cancel()
 }
 func targetChanged(to revision: UInt64, input: InputContext) {
  guard let c = action?.permit.context, c.input == input, c.targetRevision < revision else { return }; cancel()
 }
 func cancel() {
  guard let a = action else { return }
  a.permit.cancel(); a.cancelTimer?(); action = nil
  // job remains occupied until its own completion retires it, including failed/queued probes.
 }
 private func begin(_ context: ZoomActionContext, reset: Bool) {
  cancel(); action = Action(context, reset: reset); pump()
 }
 private func pump() {
  guard let a = action, a.permit.current, job == nil, !a.scheduled else { return }
  guard let target = a.target else {
   start(a, returnedStage: "probeReturned") { ticket in try self.probe(ticket) } completed: { result in
    switch result { case .success(let target):
     // An ended continuous contact never replays movement gathered while probing.
     if target.supportsContinuousZoom, a.terminal, !a.resetting { self.cancel(); return }
     a.target = target; self.onStrategy(target.strategy); self.pump()
    case .failure(let error): self.failed(error) }
   }
   return
  }
  if target.supportsContinuousZoom, !a.resetting {
   guard !a.terminal else { cancel(); return }
   let now = clock()
   if let batch = a.pixels.take(now: now) {
    start(a, expiresAt: batch.expiresAt) { ticket in
     try target.executePixelZoom(batch.delta, permit: ticket)
    } completed: { result in
     switch result {
     case .success:
      if !a.pixelStatusShown { a.pixelStatusShown = true; self.onStatus("已发送连续应用缩放") }
      self.pump()
     case .failure(ZoomFailure.cancelled): self.pump() // expired batch; a newer fresh demand may remain
     case .failure(let error): self.failed(error)
     }
    }
   } else if let delay = a.pixels.delay(now: now) { schedule(a, delay: delay) }
   return
  }
  let now = clock(), command: ZoomCommand?
  if a.resetting { command = .reset; a.resetting = false } else { command = a.steps.take(now: now) }
  guard let command else {
   // H1: take(), not completion/post, starts the unchanged 180 ms interval.
   if let remaining = a.steps.delayUntilNextStep(now: now) {
    schedule(a, delay: remaining)
   } else if a.terminal { cancel() }
   return
  }
  start(a) { ticket in try target.execute(command, permit: ticket) } completed: { result in
   switch result {
   case .success: self.onSubmitted(command); self.onStatus("已发送应用缩放命令"); self.pump()
   case .failure(let error): self.failed(error)
   }
  }
 }
 private func schedule(_ a: Action, delay: UInt64) {
  a.scheduled = true
  a.cancelTimer = schedule(delay) { [weak self, weak a] in
   guard let self, let a, self.action === a, a.permit.current else { return }
   a.scheduled = false; a.cancelTimer = nil; self.pump()
  }
 }
 private func start<T>(_ a: Action, expiresAt: UInt64? = nil, returnedStage: String = "executeReturned", work: @escaping (ZoomPermit) throws -> T, completed: @escaping (Result<T, Error>) -> Void) {
  let id = UUID(); job = Job(id: id, action: a)
  let report = onStage
  let ticket = a.permit.forJob(id, expiresAt: expiresAt, clock: clock) { stage, time in if let c = a.permit.context { report(c, id, stage, time) } }
  enqueueWorker { [weak self] in
   guard let self else { return }
   // Even a cancelled job must report completion to retire its physical slot.
   let result = Result { guard ticket.current else { throw ZoomFailure.cancelled }; return try work(ticket) }
   if let c = ticket.context { report(c, id, returnedStage, self.clock()) }
   self.enqueueCompletion {
    guard self.job?.id == id else { return }
    self.job = nil
    if let c = ticket.context { report(c, id, "jobRetired", self.clock()) }
    if self.action === a, a.permit.current { completed(result) }
    else { self.pump() } // Only the current action may use the freed resource; never the old result.
   }
  }
 }
 private func failed(_ error: Error) {
  onFailure((error as? ZoomFailure)?.diagnosticCode ?? "unexpectedError")
  if let failure = error as? ZoomFailure, case .automationDenied = failure { onStatus("请在系统设置 › 隐私与安全性 › 自动化中允许 PadInk 控制 PowerPoint") }
  else { onStatus("当前应用或视图没有可用的公开缩放命令，可用手指操作应用自己的缩放控件") }
  onStrategy("zoomUnavailable"); cancel()
 }
}
#endif
