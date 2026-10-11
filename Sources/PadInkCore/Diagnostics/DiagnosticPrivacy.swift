import Foundation

extension Trace {
 /// Keep performance measurements only. In particular, value can also contain pressure or
 /// movement deltas, and state may contain geometry or an interpolated error description.
 private static let supportValueStages: Set<String> = [
  "input.captureToSend", "input.receiveToInject", "video.receiveToPresent", "video.encoded", "video.decoded",
  "video.send", "video.received", "input.senderStall", "usb.dial", "video.profile"
 ]
 private static let supportTouchStates: Set<String> = Set(["pointer", "scroll", "magnify"].flatMap { kind in
  ["began", "changed", "ended", "cancelled"].map { kind + ":" + $0 }
 })
 static func fixedCode(_ value: String, limit: Int = 80) -> Bool {
  !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy {
   (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
  }
 }
 func supportSafe() -> Trace {
  var safe = self
  if !Self.fixedCode(safe.stage) { safe.stage = "redacted" }
  safe.x = nil; safe.y = nil; safe.pressure = nil; safe.altitude = nil; safe.azimuth = nil
  safe.screenX = nil; safe.screenY = nil; safe.viewX = nil; safe.viewY = nil
  safe.state = ["touch.receive", "touch.inject"].contains(stage) && state.map(Self.supportTouchStates.contains) == true ? state : nil
  safe.sourceTime = nil; safe.eventTime = nil
  safe.estimatedProperties = nil; safe.expectingUpdates = nil; safe.estimationIndex = nil
  if !Self.supportValueStages.contains(stage) || safe.value?.isFinite == false { safe.value = nil }
  return safe
 }
}

extension DiagnosticReport {
 /// Export event clocks as elapsed time within this report. Cross-device uptime estimates and
 /// raw source/event timestamps are unnecessary for a user support bundle.
 func supportSafe() -> DiagnosticReport {
  var safe = self
  safe.performance = nil
  safe.detail = "support"; safe.clockBasis = "elapsedWithinReportNanoseconds"
  safe.session?.clock = nil
  safe.previousUnfinishedSession = previousUnfinishedSession?.supportSafe()
  safe.traces = traces.map { $0.supportSafe() }
  safe.counters = counters.filter { Trace.fixedCode($0.key) }
  safe.faults = faults?.filter { Trace.fixedCode($0.reason) && $0.reason.utf8.count <= 80 }
  let times = safe.traces.map(\.time) + (safe.faults ?? []).map(\.time) + (safe.actions ?? []).map(\.time)
  let origin = times.min() ?? 0
  safe.traces = safe.traces.map { var t = $0; t.time -= origin; return t }
  safe.faults = safe.faults?.map { FaultRecord(time: $0.time - origin, generation: $0.generation, row: $0.row, reason: $0.reason) }
  safe.actions = safe.actions?.map { var action = $0; action.time -= origin; return action }
  return safe
 }
}
