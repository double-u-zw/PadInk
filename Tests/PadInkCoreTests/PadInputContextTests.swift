import XCTest
@testable import PadInkCore

/// Real, handshaken wire paths through PadCoordinator's capture callbacks.
final class PadInputContextTests: XCTestCase {
 private final class World {
  let mac: Attachment, host: PadAttachmentHost
  var video: (FakeStream, FakeStream), frames: [Frame] = []
  init(_ mac: Attachment, _ host: PadAttachmentHost, _ video: (FakeStream, FakeStream)) { self.mac = mac; self.host = host; self.video = video }
  var pad: Attachment { host.current! }
 }
 private let q = DispatchQueue(label: "test.input.context")
 private var streams: [FakeStream] = [], jobs: [() -> Void] = []
 private var now: UInt64 = 1_000_000_000, context: InputContext?
 private let diagnostics = Diagnostics()
 private lazy var link = PadInputLink(diagnostics: diagnostics, clock: { [unowned self] in self.now })
 private lazy var callbacks = PadInputCallbacks(link: link, context: { [unowned self] in self.context }, enqueue: { [unowned self] in self.jobs.append($0) })
 private func pair() -> (FakeStream, FakeStream) { let p = FakeStream.pair(); streams += [p.0, p.1]; return p }
 private func settle() { for _ in 0..<12 { streams.forEach { $0.settle() }; q.sync {} } }
 private func flush() { let pending = jobs; jobs.removeAll(); pending.forEach { job in q.async { job() } }; settle() }
 private func connect(generation: UInt32 = 1) throws -> World {
  let clock = { [unowned self] in self.now }
  let host = PadAttachmentHost(local: { LocalIdentity(appVersion: "0.3.0", deviceID: Data(repeating: 2, count: 32)) }, queue: q, clock: clock)
  let mac = Attachment(role: .mac, attachmentID: UUID(), generation: generation, local: LocalIdentity(appVersion: "0.3.0", deviceID: Data(repeating: 1, count: 32)), queue: q, clock: clock)
  let control = pair(), video = pair(), world = World(mac, host, video)
  host.onAttachment = { $0.onEvent = { _ in } }
  mac.onEvent = { [weak world] event in if case .frame(.controlInput, let frame, _) = event { world?.frames.append(frame) } }
  q.sync { host.accept(control.1); host.accept(video.1); mac.start(control: control.0, video: video.0) }; settle()
  XCTAssertTrue(q.sync { mac.isReady }); XCTAssertTrue(q.sync { host.current?.isReady == true })
  _ = try XCTUnwrap(host.current)
  return world
 }
 private func adopt(_ w: World) { q.sync { link.adopt(w.pad) }; context = InputContext(w.pad) }
 private func pencil(_ id: UInt64) -> PencilSample { PencilSample(stroke: id, sequence: 1, timestamp: now, x: 0.5, y: 0.5, pressure: 0.5, altitude: 1, azimuth: 0, phase: .begin, geometryGeneration: 1) }
 private func touch(_ id: UInt64) -> TouchEvent { TouchEvent(gestureID: (1 << 63) | id, sequence: 1, timestamp: now, geometryGeneration: 1, kind: .pointer, phase: .began, x: 0.5, y: 0.5) }
 private func geometry(_ generation: UInt32) -> PresentedGeometry { PresentedGeometry(generation: generation, ready: true, orientation: 4, videoWidth: 1000, videoHeight: 500) }
 private func queuedPayload(_ kind: MessageType, sameGeneration: Bool = false) throws {
  let a = try connect(), b = try connect(generation: sameGeneration ? 1 : 2)
  func capture(_ id: UInt64) {
   switch kind {
   case .pencil: callbacks.pencil([pencil(id)])
   case .pointer: callbacks.touch(touch(id))
   default: callbacks.geometry(geometry(UInt32(id)))
   }
  }
  adopt(a); capture(10); flush()
  XCTAssertEqual(a.frames.map(\.type), [kind], "A positive control must arrive")
  capture(11) // Same product callback freezes A; its queued work is deliberately held.
  let oldJobs = jobs; jobs.removeAll()
  q.sync { a.pad.finish(.replaced); link.ended(a.pad) }; adopt(b)
  capture(20); flush()
  XCTAssertEqual(b.frames.map(\.type), [kind], "B positive control before any negative assertion")
  let expected = b.frames
  jobs = oldJobs; flush()
  XCTAssertEqual(b.frames, expected, "Queued A payload must not borrow B's identity")
  capture(21); flush()
  XCTAssertEqual(b.frames.count, 2, "B remains usable after rejecting A")
  XCTAssertEqual(b.frames.last?.generation, b.mac.generation)
 }
 func testQueuedPencilFromOldAttachmentDoesNotReachNewAttachment() throws { try queuedPayload(.pencil) }
 func testQueuedTouchFromOldAttachmentDoesNotReachNewAttachment() throws { try queuedPayload(.pointer) }
 func testQueuedGeometryFromOldAttachmentDoesNotReachNewAttachment() throws { try queuedPayload(.presentedGeometry) }
 func testQueuedPayloadsRejectDifferentUUIDWithSameGeneration() throws { for kind in [MessageType.pencil, .pointer, .presentedGeometry] { try queuedPayload(kind, sameGeneration: true) } }
 func testNilAndWrongGenerationContextsCannotSendPayloads() throws {
  let b = try connect(); adopt(b)
  callbacks.pencil([pencil(20)]); callbacks.touch(touch(20)); callbacks.geometry(geometry(1)); flush()
  XCTAssertEqual(b.frames.count, 3, "B positive controls")
  let expected = b.frames
  for invalid in [nil, InputContext(attachmentID: b.pad.attachmentID, generation: b.pad.generation + 1)] {
   context = invalid; callbacks.pencil([pencil(11)]); callbacks.touch(touch(11)); callbacks.geometry(geometry(2)); flush()
   XCTAssertEqual(b.frames, expected)
  }
  context = InputContext(b.pad); callbacks.pencil([pencil(21)]); flush(); XCTAssertEqual(b.frames.count, 4)
 }
 private func staleGesture(pencil: Bool, clear: Bool) throws {
  let a = try connect(), b = try connect(generation: 2); adopt(a)
  let oldID: UInt64 = pencil ? 11 : (1 << 63) | 11, newID: UInt64 = pencil ? 20 : (1 << 63) | 20
  if pencil { callbacks.pencilGesture(clear ? nil : (oldID, 1)) } else { callbacks.touchGesture(clear ? nil : (oldID, 1)) }
  let oldJobs = jobs; jobs.removeAll(); adopt(b)
  if pencil { callbacks.pencilGesture((newID, 7)) } else { callbacks.touchGesture((newID, 7)) }; flush()
  now += 250_000_000; q.sync { link.tick() }; settle()
  XCTAssertEqual(try GestureKeepalive(XCTUnwrap(b.frames.last).payload).gestureID, newID, "B keepalive positive control")
  now += 100_000_000; jobs = oldJobs; flush()
  XCTAssertEqual(pencil ? link.pencilGesture?.0 : link.touchGesture?.0, newID)
  XCTAssertEqual(pencil ? link.pencilGesture?.1 : link.touchGesture?.1, 7)
  now += 100_000_000; q.sync { link.tick() }; settle()
  XCTAssertEqual(b.frames.count, 2, "Old nil must not suppress B keepalive")
  XCTAssertEqual(try GestureKeepalive(XCTUnwrap(b.frames.last).payload).gestureID, newID, "Old state must not emit A keepalive on B")
 }
 func testStalePencilStateCannotOverwriteNewGestureOrKeepalive() throws { try staleGesture(pencil: true, clear: false) }
 func testStalePencilNilCannotClearNewGestureOrKeepalive() throws { try staleGesture(pencil: true, clear: true) }
 func testStaleTouchStateCannotOverwriteNewGestureOrKeepalive() throws { try staleGesture(pencil: false, clear: false) }
 func testStaleTouchNilCannotClearNewGestureOrKeepalive() throws { try staleGesture(pencil: false, clear: true) }
 func testNilContextCannotChangeGestureStateOrKeepaliveTiming() throws {
  let b = try connect(); adopt(b); callbacks.pencilGesture((20, 7)); callbacks.touchGesture(((1 << 63) | 20, 7)); flush()
  now += 250_000_000; q.sync { link.tick() }; settle(); XCTAssertEqual(b.frames.count, 1)
  now += 250_000_000; context = nil; callbacks.pencilGesture(nil); callbacks.touchGesture(nil); flush()
  q.sync { link.tick() }; settle()
  XCTAssertEqual(link.pencilGesture?.0, 20); XCTAssertEqual(link.touchGesture?.0, (1 << 63) | 20); XCTAssertEqual(b.frames.count, 2)
 }
 func testAdoptNewIdentityClearsOldGestureStateWithoutEnded() throws {
  let a = try connect(), b = try connect(); adopt(a)
  callbacks.pencilGesture((11, 1)); callbacks.touchGesture(((1 << 63) | 11, 1)); flush()
  now += 250_000_000; q.sync { link.tick() }; settle(); XCTAssertEqual(a.frames.count, 1)
  adopt(b); callbacks.pencil([pencil(20)]); flush(); XCTAssertEqual(b.frames.count, 1, "B positive control")
  XCTAssertNil(link.pencilGesture); XCTAssertNil(link.touchGesture)
  now += 250_000_000; q.sync { link.tick() }; settle(); XCTAssertEqual(b.frames.count, 1)
 }
 func testRepeatedAdoptAndOldEndedDoNotClearCurrentGesture() throws {
  let a = try connect(), b = try connect(); adopt(a); adopt(b)
  callbacks.pencilGesture((20, 7)); callbacks.touchGesture(((1 << 63) | 20, 7)); flush()
  q.sync { link.adopt(b.pad); link.ended(a.pad) }
  XCTAssertTrue(link.attachment === b.pad); XCTAssertEqual(link.pencilGesture?.0, 20); XCTAssertEqual(link.touchGesture?.0, (1 << 63) | 20)
  now += 250_000_000; q.sync { link.tick() }; settle(); XCTAssertEqual(b.frames.count, 1)
 }
 func testEndedAttachmentRejectsPayloadAndStopsKeepalive() throws {
  let b = try connect(); adopt(b); callbacks.pencil([pencil(20)]); callbacks.pencilGesture((20, 7)); flush()
  now += 250_000_000; q.sync { link.tick() }; settle(); XCTAssertEqual(b.frames.count, 2)
  q.sync { b.pad.finish(.closedLocally(nil)) }
  callbacks.pencil([pencil(21)]); callbacks.pencilGesture((21, 1)); flush()
  XCTAssertEqual(link.pencilGesture?.0, 20, "Ended attachment rejects state changes")
  q.sync { link.ended(b.pad) }; now += 250_000_000; q.sync { link.tick() }; settle()
  XCTAssertNil(link.pencilGesture); XCTAssertEqual(b.frames.count, 2)
 }
 func testInputRejectedClearsOnlyMatchingGesture() throws {
  let b = try connect(); adopt(b); callbacks.pencilGesture((20, 7)); callbacks.touchGesture(((1 << 63) | 20, 7)); flush()
  q.sync { link.rejected(GestureNotice(gestureID: 20, reason: .geometryMismatch)) }
  XCTAssertNil(link.pencilGesture); XCTAssertEqual(link.touchGesture?.0, (1 << 63) | 20)
 }
 func testBOnlyRecoveryKeepsMatchingControlInputUsable() throws {
  let w = try connect(); adopt(w); callbacks.pencil([pencil(10)]); flush(); XCTAssertEqual(w.frames.count, 1)
  w.video.0.fail(); settle()
  XCTAssertNil(w.pad.ended)
  callbacks.pencil([pencil(11)]); callbacks.touch(touch(11)); callbacks.geometry(geometry(2)); flush()
  XCTAssertEqual(w.frames.map(\.type), [.pencil, .pencil, .pointer, .presentedGeometry], "Existing A send rules survive B-only failure")
  let original = w.pad; w.video = pair()
  q.sync { w.host.accept(w.video.1); w.mac.replaceVideo(w.video.0) }; settle()
  XCTAssertTrue(w.host.current === original); XCTAssertTrue(q.sync { w.pad.isReady })
  callbacks.pencil([pencil(12)]); flush(); XCTAssertEqual(w.frames.count, 5)
 }
 func testOldPresentedCallbackCannotReadyNewGeometryWithSameNumericGeneration() {
  let a = InputContext(attachmentID: UUID(), generation: 1), b = InputContext(attachmentID: UUID(), generation: 1)
  var current: InputContext? = a, geometry = PencilGeometryState()
  let value = VideoGeometry(source: CGSize(width: 1000, height: 500), bounds: CGRect(x: 0, y: 0, width: 1000, height: 500))
  geometry.update(value, orientation: 4)
  InputContext.presentedCallback(context: a, current: { current }, presented: { geometry.presented(generation: 1) })()
  XCTAssertTrue(geometry.ready, "A positive presentation control")
  let old = InputContext.presentedCallback(context: a, current: { current }, presented: { geometry.presented(generation: 1) })
  current = b; geometry = PencilGeometryState(); geometry.update(value, orientation: 4)
  old(); XCTAssertFalse(geometry.ready)
  InputContext.presentedCallback(context: b, current: { current }, presented: { geometry.presented(generation: 1) })()
  XCTAssertTrue(geometry.ready, "B remains presentable")
 }
 func testActionJournalCorrelatesCaptureAdmissionSendAndStaleDrop() throws {
  let a = try connect(), b = try connect(generation: 2); adopt(a)
  callbacks.pencil([pencil(11)]); let oldJobs = jobs; jobs.removeAll(); adopt(b)
  callbacks.pencil([pencil(20)]); flush(); XCTAssertEqual(b.frames.count, 1)
  jobs = oldJobs; flush(); XCTAssertEqual(b.frames.count, 1)
  let old = diagnostics.actionJournal { $0.gesture == 11 }
  XCTAssertEqual(old.map(\.stage), [.capture, .drop])
  XCTAssertTrue(old.allSatisfy { $0.attachmentID == a.pad.attachmentID && $0.generation == 1 && $0.sequence == 1 && $0.geometryGeneration == 1 })
  XCTAssertEqual(old.last?.reason, .identityMismatch)
  let fresh = diagnostics.actionJournal { $0.gesture == 20 }
  XCTAssertEqual(fresh.map(\.stage), [.capture, .admission, .sendAdmitted])
  XCTAssertTrue(fresh.allSatisfy { $0.attachmentID == b.pad.attachmentID && $0.generation == 2 })
 }
 func testJournalOverflowAndExportFailureDoNotChangeInputAdmission() throws {
  let b = try connect(); adopt(b)
  for n in 0..<(Diagnostics.actionCapacity + 2) { diagnostics.action(.capture, context: context, kind: .geometry, gesture: UInt64(n)) }
  XCTAssertEqual(diagnostics.droppedActionRecords, 2)
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data().write(to: file); defer { try? FileManager.default.removeItem(at: file) }
  XCTAssertThrowsError(try diagnostics.export(to: file))
  callbacks.pencil([pencil(20)]); callbacks.touch(touch(20)); callbacks.geometry(geometry(1)); flush()
  XCTAssertEqual(b.frames.map(\.type), [.pencil, .pointer, .presentedGeometry])
  XCTAssertEqual(diagnostics.actionJournal().count, Diagnostics.actionCapacity)
  XCTAssertGreaterThan(diagnostics.droppedActionRecords, 2)
 }

 private func dispatchQueuePayload(_ kind: MessageType) throws {
  let a = try connect(), b = try connect(generation: 2); adopt(a)
  let oldPencil = pencil(11), oldTouch = touch(11), oldGeometry = geometry(11)
  let freshPayload: Data
  switch kind {
  case .pencil: callbacks.pencil([pencil(10)]); freshPayload = try PencilBatch([pencil(20)]).encoded()
  case .pointer: callbacks.touch(touch(10)); freshPayload = try touch(20).encoded()
  default: callbacks.geometry(geometry(10)); freshPayload = geometry(20).encoded()
  }
  flush(); XCTAssertEqual(a.frames.map(\.type), [kind], "A positive control")
  XCTAssertTrue(q.sync { b.pad.send(kind, payload: freshPayload, on: .controlInput) }); settle()
  XCTAssertEqual(b.frames.map(\.type), [kind], "B can send before holding the real input queue")
  let expected = b.frames, entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
  let live = PadInputCallbacks(link: link, context: { self.context }, enqueue: { job in self.q.async { job() } })
  q.async { entered.signal(); resume.wait() }
  guard entered.wait(timeout: .now() + 2) == .success else { resume.signal(); return XCTFail("input queue did not pause") }
  // Attachment replacement is already queued while the main-thread capture identity still says A.
  q.async { a.pad.finish(.replaced); self.link.ended(a.pad); self.link.adopt(b.pad) }
  switch kind { case .pencil: live.pencil([oldPencil]); case .pointer: live.touch(oldTouch); default: live.geometry(oldGeometry) }
  resume.signal(); settle()
  XCTAssertEqual(b.frames, expected, "Real queue.async must not rebind the queued A work")
  context = InputContext(b.pad)
  switch kind { case .pencil: live.pencil([pencil(21)]); case .pointer: live.touch(touch(21)); default: live.geometry(geometry(21)) }
  settle(); XCTAssertEqual(b.frames.count, 2, "B still works after the old closure returns")
 }
 func testRealDispatchQueuePencilCaptureRemainsBoundToOldAttachment() throws { try dispatchQueuePayload(.pencil) }
 func testRealDispatchQueueTouchCaptureRemainsBoundToOldAttachment() throws { try dispatchQueuePayload(.pointer) }
 func testRealDispatchQueueGeometryCaptureRemainsBoundToOldAttachment() throws { try dispatchQueuePayload(.presentedGeometry) }
 func testWrongGenerationStateCannotChangeCurrentGestures() throws {
  let b = try connect(); adopt(b); callbacks.pencilGesture((20, 7)); callbacks.touchGesture(((1 << 63) | 20, 7)); flush()
  context = InputContext(attachmentID: b.pad.attachmentID, generation: b.pad.generation + 1)
  callbacks.pencilGesture((11, 1)); callbacks.touchGesture(((1 << 63) | 11, 1)); callbacks.pencilGesture(nil); callbacks.touchGesture(nil); flush()
  XCTAssertEqual(link.pencilGesture?.0, 20); XCTAssertEqual(link.touchGesture?.0, (1 << 63) | 20)
  now += 250_000_000; q.sync { link.tick() }; settle()
  XCTAssertEqual(try GestureKeepalive(XCTUnwrap(b.frames.last).payload).gestureID, 20)
 }
 func testPresentationCallbackRejectsNilAndDifferentGeneration() {
  let current = InputContext(attachmentID: UUID(), generation: 2)
  var count = 0
  for captured in [nil, InputContext(attachmentID: current.attachmentID, generation: 1)] {
   InputContext.presentedCallback(context: captured, current: { current }, presented: { count += 1 })()
  }
  XCTAssertEqual(count, 0)
  InputContext.presentedCallback(context: current, current: { nil }, presented: { count += 1 })()
  XCTAssertEqual(count, 0)
  InputContext.presentedCallback(context: current, current: { current }, presented: { count += 1 })()
  XCTAssertEqual(count, 1)
 }
 func testActionJournalHasOrderedBoundedMetadataAndRoundTrips() throws {
  let identity = InputContext(attachmentID: UUID(), generation: 3)
  for n in 0..<(Diagnostics.actionCapacity + 3) {
   diagnostics.action(.drop, context: identity, kind: .pencil, gesture: 11, sequence: 7, geometryGeneration: 2, reason: .identityMismatch, time: UInt64(n))
  }
  let records = diagnostics.actionJournal()
  XCTAssertEqual(records.count, Diagnostics.actionCapacity); XCTAssertEqual(records.first?.ordinal, 4)
  XCTAssertEqual(records.last?.ordinal, UInt64(Diagnostics.actionCapacity + 3)); XCTAssertEqual(diagnostics.droppedActionRecords, 3)
  let encoded = try JSONEncoder().encode(XCTUnwrap(records.last))
  let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  XCTAssertEqual(Set(fields.keys), ["ordinal", "time", "stage", "attachmentID", "generation", "kind", "gesture", "sequence", "geometryGeneration", "reason"])
  for n in 0..<100 { diagnostics.mark("video.presented", time: UInt64(n)) }
  let report = try JSONDecoder().decode(DiagnosticReport.self, from: JSONEncoder().encode(diagnostics.report()))
  XCTAssertEqual(report.actions, records); XCTAssertEqual(report.droppedActionRecords, 3)
 }

 func testOldWriterCompletionCannotDrainReplacementPendingInput() throws {
  let a = try connect(), b = try connect(generation: 1); adopt(a)
  callbacks.pencil([pencil(10)]); flush(); XCTAssertEqual(a.frames.count, 1)
  streams[1].stall(); callbacks.pencil([pencil(11)]); callbacks.pencil([pencil(12)]); flush()
  XCTAssertEqual(a.frames.count, 1)
  q.sync { link.adopt(b.pad); link.sendPencil([pencil(20)], context: InputContext(b.pad)); a.pad.finish(.replaced) }
  context = InputContext(b.pad); settle()
  XCTAssertEqual(try PencilBatch(XCTUnwrap(b.frames.first).payload).gestureID, 20)
  XCTAssertEqual(b.frames.count, 1, "old writer completion must not send any A pending frame on B")
  callbacks.pencil([pencil(21)]); flush(); XCTAssertEqual(b.frames.count, 2)
 }

}
