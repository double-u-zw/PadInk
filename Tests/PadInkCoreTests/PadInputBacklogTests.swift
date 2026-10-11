import XCTest
@testable import PadInkCore

/// Handshaken A/B streams and the Mac's real freshness/ownership/transactional Pencil model.
/// A stationary writer and a held capture queue use explicit barriers, never wall-clock sleeps.
final class PadInputBacklogTests: XCTestCase {
 private final class Fixture {
  let queue = DispatchQueue(label: "test.input.backlog")
  var now: UInt64 = 1_000_000_000
  let diagnostics = Diagnostics()
  var streams: [FakeStream] = [], jobs: [() -> Void] = [], frames: [Frame] = []
  var mac: Attachment!, host: PadAttachmentHost!, control: (FakeStream, FakeStream)!
  var pencil = InputOwnership(), session = InputSession()
  var injected: [PencilSample] = [], actions: [TabletAction] = []
  var touch: TouchOwnership = { var value = TouchOwnership(); value.enabled = true; return value }()
  var touched: [TouchEvent] = [], touchReleases = 0
  lazy var link = PadInputLink(diagnostics: diagnostics, clock: { self.now })
  lazy var callbacks = PadInputCallbacks(link: link, context: { self.link.attachment.map(InputContext.init) }, enqueue: { self.jobs.append($0) })
  init() throws {
   let clock = { [unowned self] in self.now }
   host = PadAttachmentHost(local: { LocalIdentity(appVersion: "0.3.0", deviceID: Data(repeating: 2, count: 32)) }, queue: queue, clock: clock)
   mac = Attachment(role: .mac, attachmentID: UUID(), generation: 1, local: LocalIdentity(appVersion: "0.3.0", deviceID: Data(repeating: 1, count: 32)), queue: queue, clock: clock)
   control = pair(); let video = pair()
   host.onAttachment = { [unowned self] a in a.onEvent = { [unowned self, weak a] event in if case .ended = event, let a { self.link.ended(a) } } }
   mac.onEvent = { [unowned self] event in self.receive(event) }
   queue.sync { host.accept(control.1); host.accept(video.1); mac.start(control: control.0, video: video.0) }; settle()
   let pad = try XCTUnwrap(host.current); XCTAssertTrue(pad.isReady)
   queue.sync { link.adopt(pad); link.sendGeometry(PresentedGeometry(generation: 1, ready: true, orientation: 4, videoWidth: 1000, videoHeight: 500), context: InputContext(pad)) }; settle()
  }
  func pair() -> (FakeStream, FakeStream) { let pair = FakeStream.pair(); streams += [pair.0, pair.1]; return pair }
  func settle() { for _ in 0..<16 { streams.forEach { $0.settle() }; queue.sync {} } }
  func flush() { let pending = jobs; jobs.removeAll(); pending.forEach { job in queue.async { job() } }; settle() }
  func sample(_ sequence: UInt64, _ phase: PencilPhase, stroke: UInt64 = 1) -> PencilSample {
   PencilSample(stroke: stroke, sequence: sequence, timestamp: now + sequence, x: Float(sequence % 100) / 100, y: 0.5, pressure: 0.6, altitude: 1, azimuth: 0, phase: phase, geometryGeneration: 1)
  }
  func send(_ samples: [PencilSample]) { callbacks.pencil(samples); flush() }
  private func execute(_ commands: [InputOwnership.Command]) {
   for command in commands {
    switch command {
    case .inject(let batch):
     let samples = batch.pencilSamples
     do { actions += try session.consume(samples); injected += samples; pencil.injected(batch) }
     catch { XCTFail("product transaction rejected valid fixture: \(error)") }
    case .release: actions += session.reset()
    case .reject: break
    }
   }
  }
  func touchEvent(_ sequence: UInt32, _ phase: TouchPhase, kind: TouchKind = .pointer, id: UInt64 = 1) -> TouchEvent {
   TouchEvent(gestureID: (1 << 63) + id, sequence: sequence, timestamp: now, geometryGeneration: 1,
    kind: kind, phase: phase, x: 0.5, y: 0.5, dx: kind == .magnify && phase == .changed ? 0.01 : 0,
    dy: kind == .scroll && phase == .changed ? 0.01 : 0)
  }
  private func executeTouch(_ commands: [TouchOwnership.Command]) {
   for command in commands {
    switch command {
    case .inject(let event): touched.append(event); touch.delivered(event)
    case .release: touchReleases += 1
    case .reject: break
    }
   }
  }
  private func receive(_ event: AttachmentEvent) {
   switch event {
   case .frame(.controlInput, let frame, let stamp):
    frames.append(frame)
    do {
     switch frame.type {
     case .presentedGeometry:
      let geometry = try PresentedGeometry(frame.payload)
      execute(pencil.presentedGeometry(geometry)); executeTouch(touch.updateGeometry(geometry))
     case .pencil: execute(pencil.pencil(try PencilBatch(frame.payload), stamp: stamp, now: now))
     case .inputCancel:
      let notice = try GestureNotice(frame.payload); execute(pencil.cancelFromPeer(notice))
      if touch.active?.gestureID == notice.gestureID { executeTouch(touch.cancel(notice.reason)) }
     case .pointer, .scroll, .magnify:
      executeTouch(touch.receive(try TouchEvent(frame.payload, type: frame.type), stamp: stamp, now: now, pencilActive: pencil.active != nil))
     case .gestureKeepalive: execute(pencil.keepalive(try GestureKeepalive(frame.payload), stamp: stamp, now: now))
     default: break
     }
    } catch { XCTFail("fixture wire decode failed: \(error)") }
   case .ended: execute(pencil.cancelAll(.transportLost)); executeTouch(touch.cancel(.transportLost))
   default: break
   }
  }
 }
 func testHeldCaptureQueueDoesNotReclassifyOldPencilAsFreshMacInput() throws {
  let f = try Fixture(); var rejected: [GestureNotice] = []
  f.link.onRejected = { _, notice in rejected.append(notice) }
  f.callbacks.pencil([f.sample(1, .begin)]); f.now += 500_000_000; f.flush()
  XCTAssertTrue(f.injected.isEmpty, "the receiver's local receive stamp must not hide an old source queue")
  XCTAssertEqual(rejected.map(\.gestureID), [1], "expire the whole unsent gesture locally")
  XCTAssertNil(f.pencil.active); XCTAssertNil(f.session.active)
 }
 func testStalledWriterIsClosedBeforeResumeCanReplayOldMovement() throws {
  let f = try Fixture(); f.send([f.sample(1, .begin)])
  let pad = try XCTUnwrap(f.link.attachment); f.control.1.stall()
  for sequence: UInt64 in 2...101 { f.callbacks.pencil([f.sample(sequence, .move)]) }
  f.flush(); XCTAssertGreaterThan(f.control.1.queuedBytes, 0)
  f.now += 500_000_000; f.queue.sync { f.link.tick() }; f.settle()
  XCTAssertNotNil(pad.ended, "a cancel frame behind the same blocked writer cannot purge accepted bytes")
  f.control.1.resume(); f.settle()
  XCTAssertEqual(f.injected.count, 1, "old input must not drain into the still-matching attachment")
  XCTAssertEqual(f.actions.filter { if case .up = $0 { return true }; return false }.count, 1)
  XCTAssertNil(f.session.active)
 }
 func testCaptureWakeIsBoundedAndOverflowCancelsInsteadOfPartiallyReplaying() throws {
  let f = try Fixture()
  for sequence: UInt64 in 1...2000 { f.callbacks.pencil([f.sample(sequence, sequence == 1 ? .begin : .move)]) }
  XCTAssertEqual(f.jobs.count, 1, "capture retains one wake, not one closure containing samples per callback")
  f.flush(); XCTAssertTrue(f.injected.isEmpty)
  XCTAssertNil(f.session.active); XCTAssertNil(f.pencil.active)
 }
 func testBriefWriterDelayPreservesEveryActualPointAndTheTerminal() throws {
  let f = try Fixture(); let first = f.sample(1, .begin); f.send([first]); f.control.1.stall()
  let movement = (2...257).map { f.sample(UInt64($0), .move) }, terminal = f.sample(258, .end)
  f.callbacks.pencil(movement); f.callbacks.pencil([terminal]); f.flush()
  f.now += 20_000_000; f.control.1.resume(); f.settle()
  XCTAssertEqual(f.injected, [first] + movement + [terminal])
  XCTAssertNil(f.session.active); XCTAssertNil(f.pencil.active)
  XCTAssertNil(f.mac.ended)
  XCTAssertEqual(f.actions.filter { if case .up = $0 { return true }; return false }.count, 1)
 }
 func testCurrentHundredMillisecondBoundaryPreservesWholeStrokeAndFutureSequence() throws {
  let f = try Fixture(); let first = f.sample(1, .begin)
  f.callbacks.pencil([first]); f.now += 100_000_000; f.flush()
  let terminal = f.sample(2, .end); f.send([terminal])
  XCTAssertEqual(f.injected, [first, terminal]); XCTAssertNil(f.session.active)
  XCTAssertEqual(f.link.queueSnapshot.droppedGestures, 0); XCTAssertNil(f.mac.ended)
 }
 func testExpiredContinuationCancelsOnceAndFreshSameGestureCannotRevive() throws {
  let f = try Fixture(); var rejected: [GestureNotice] = []
  f.link.onRejected = { _, notice in rejected.append(notice) }
  f.send([f.sample(1, .begin)])
  f.callbacks.pencil([f.sample(2, .move)]); f.now += 101_000_000; f.flush()
  f.send([f.sample(3, .move)]); f.send([f.sample(4, .end)])
  f.callbacks.pencilGesture((1, 4)); f.flush(); f.now += 200_000_000
  f.queue.sync { f.link.tick() }; f.settle()
  XCTAssertEqual(f.injected.count, 1); XCTAssertEqual(rejected.count, 1)
  XCTAssertNil(f.link.pencilGesture); XCTAssertNil(f.session.active); XCTAssertNil(f.mac.ended)
  f.send([f.sample(1, .begin, stroke: 2)]); f.send([f.sample(2, .end, stroke: 2)])
  XCTAssertEqual(f.injected.map(\.stroke), [1, 2, 2], "a fresh later gesture remains usable on the same A")
  XCTAssertEqual(f.link.queueSnapshot.droppedGestures, 1)
 }
 func testSlowDrainUsesOneStreamFrameAndCancelsOldPendingInsteadOfSkippingPoints() throws {
  let f = try Fixture(); f.send([f.sample(1, .begin)]); f.control.1.stall()
  f.send([f.sample(2, .move)]); f.callbacks.pencil([f.sample(3, .move)]); f.flush()
  XCTAssertEqual(f.control.1.queuedBytes, PINK2.headerSize + PencilBatch.headerSize + PencilBatch.sampleSize)
  XCTAssertEqual(f.link.queueSnapshot.pendingFrames, 1)
  f.now += 101_000_000; f.control.1.drainOne(); f.settle()
  XCTAssertEqual(f.injected.map(\.sequence), [1, 2], "the one frame already handed to a stream cannot be retracted")
  f.control.1.drainOne(); f.settle()
  XCTAssertNil(f.session.active); XCTAssertEqual(f.injected.map(\.sequence), [1, 2])
  XCTAssertNil(f.mac.ended, "a 101ms slow write cancels the gesture without a severe-stall reconnect")
 }
 func testNormalRealFixturePreservesAllEightyFiveStrokesAnd7143Points() throws {
  struct FixtureFile: Decodable { let strokes: [[PencilSample]] }
  let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/replay/baseline-real-strokes.json")
  let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: path)), f = try Fixture()
  for stroke in fixture.strokes {
   f.send([stroke[0]])
   for start in stride(from: 1, to: stroke.count, by: 20) { f.send(Array(stroke[start..<min(start + 20, stroke.count)])) }
   XCTAssertNil(f.session.active)
  }
  XCTAssertEqual(fixture.strokes.count, 85); XCTAssertEqual(f.injected.count, 7143)
  XCTAssertEqual(f.injected, fixture.strokes.flatMap { $0 })
  XCTAssertEqual(f.link.queueSnapshot.droppedGestures, 0); XCTAssertEqual(f.link.queueSnapshot.stalls, 0)
  XCTAssertNil(f.mac.ended)
 }

 func testPointerScrollAndMagnifyExpireAsWholeGesturesWithoutResurrection() throws {
  for kind in [TouchKind.pointer, .scroll, .magnify] {
   let f = try Fixture(); var rejected: [GestureNotice] = []
   f.link.onRejected = { _, notice in rejected.append(notice) }
   f.callbacks.touch(f.touchEvent(1, .began, kind: kind)); f.flush()
   f.callbacks.touch(f.touchEvent(2, .changed, kind: kind)); f.now += 101_000_000; f.flush()
   f.callbacks.touch(f.touchEvent(3, .ended, kind: kind)); f.flush()
   f.callbacks.touchGesture(((1 << 63) + 1, 3)); f.flush()
   XCTAssertEqual(f.touched.map(\.phase), [.began]); XCTAssertEqual(f.touchReleases, 1)
   XCTAssertEqual(rejected.count, 1); XCTAssertNil(f.link.touchGesture); XCTAssertNil(f.touch.active)
   f.callbacks.touch(f.touchEvent(1, .began, kind: kind, id: 2)); f.flush()
   f.callbacks.touch(f.touchEvent(2, .changed, kind: kind, id: 2)); f.flush()
   f.callbacks.touch(f.touchEvent(3, .ended, kind: kind, id: 2)); f.flush()
   XCTAssertEqual(f.touched.map(\.phase), [.began, .began, .changed, .ended]); XCTAssertNil(f.mac.ended)
  }
 }
 func testSevereWriterStallReleasesPointerAndPreventsGhostScrollAndZoom() throws {
  for kind in [TouchKind.pointer, .scroll, .magnify] {
   let f = try Fixture(); f.callbacks.touch(f.touchEvent(1, .began, kind: kind)); f.flush()
   f.control.1.stall(); f.callbacks.touch(f.touchEvent(2, .changed, kind: kind)); f.flush()
   f.now += 250_000_000; f.queue.sync { f.link.tick() }; f.settle()
   f.control.1.resume(); f.settle()
   XCTAssertEqual(f.touched.map(\.phase), [.began]); XCTAssertEqual(f.touchReleases, 1)
   XCTAssertNil(f.touch.active); XCTAssertEqual(f.link.queueSnapshot.stalls, 1)
  }
 }
 func testSenderByteOverflowHasFiniteCancellationAndReleasesWholeStroke() throws {
  let f = try Fixture(); f.send([f.sample(1, .begin)]); f.control.1.stall()
  for batch in 0..<100 {
   let start = UInt64(batch * 256 + 2)
   f.send((start..<(start + 256)).map { f.sample($0, .move) })
   XCTAssertLessThanOrEqual(f.link.queueSnapshot.pendingBytes, 64 << 10)
   XCTAssertLessThanOrEqual(f.link.queueSnapshot.pendingFrames, 256)
   XCTAssertLessThanOrEqual(f.control.1.queuedBytes, PINK2.headerSize + PencilBatch.maxPayload)
  }
  XCTAssertEqual(f.link.queueSnapshot.droppedGestures, 1)
  f.control.1.resume(); f.settle()
  XCTAssertEqual(f.injected.count, 257, "only the already-submitted full batch can arrive before cancellation")
  XCTAssertNil(f.session.active); XCTAssertEqual(f.actions.filter { if case .up = $0 { return true }; return false }.count, 1)
  XCTAssertNil(f.mac.ended)
 }

 func testManyUnsentExpiredGesturesCannotAccumulatePriorityCancels() throws {
  let f = try Fixture(); f.send([f.sample(1, .begin)]); f.control.1.stall()
  f.send([f.sample(2, .move)]); f.callbacks.pencil([f.sample(3, .end)]); f.flush()
  for stroke: UInt64 in 2...1000 {
   f.queue.sync { f.link.sendPencil([f.sample(1, .begin, stroke: stroke)], context: f.link.attachment.map(InputContext.init), capturedAt: f.now - 101_000_000) }
  }
  XCTAssertEqual(f.link.queueSnapshot.pendingFrames, 1, "only the submitted stroke requires a wire cancel")
  XCTAssertLessThanOrEqual(f.link.queueSnapshot.pendingBytes, 52)
  f.control.1.resume(); f.settle()
  XCTAssertEqual(f.injected.map(\.stroke), [1, 1]); XCTAssertNil(f.session.active)
  XCTAssertEqual(f.frames.filter { $0.type == .inputCancel }.count, 1); XCTAssertNil(f.mac.ended)
 }

 func testStallNoticeIsQueuedBeforeAttachmentEndedClearsUICaptureIdentity() throws {
  let f = try Fixture(); f.control.1.stall(); f.send([f.sample(1, .begin)])
  let pad = try XCTUnwrap(f.link.attachment); var noticed = false
  f.link.onStall = { context in
   XCTAssertEqual(context, InputContext(pad)); XCTAssertTrue(f.link.attachment === pad)
   XCTAssertNil(pad.ended, "the main-queue notice must be enqueued before ended clears capture identity")
   noticed = true
  }
  f.now += 250_000_000; f.queue.sync { f.link.tick() }; f.settle()
  XCTAssertTrue(noticed); XCTAssertNotNil(pad.ended); XCTAssertNil(f.link.attachment)
 }

}
