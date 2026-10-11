import Foundation

public enum ZoomCommand: String, CaseIterable { case zoomIn, zoomOut, reset }
public enum ApplicationFamily: String, Codable {
 case powerpoint, preview, safari, chrome, goodnotes, ecru, generic
 public init(bundle: String) {
  switch bundle.lowercased() {
  case "com.microsoft.powerpoint": self = .powerpoint
  case "local.leafink.reader.development", "local.ecru.reader.development": self = .ecru
  case "com.apple.preview": self = .preview
  case "com.apple.safari": self = .safari
  case "com.google.chrome": self = .chrome
  default: self = bundle.lowercased().hasPrefix("com.goodnotes") ? .goodnotes : .generic
  }
 }
}
public struct ApplicationCapabilities: Equatable {
 public var pointer = true, scroll = true, pencil = false, zoomIn = false, zoomOut = false, resetZoom = false
 public init() {}
}
public struct ZoomMenuItem: Equatable {
 public let token: Int, identifier: String?, character: String?, modifiers: Int?, enabled: Bool
 public init(token: Int, identifier: String? = nil, character: String? = nil, modifiers: Int? = nil, enabled: Bool = true) { self.token = token; self.identifier = identifier; self.character = character; self.modifiers = modifiers; self.enabled = enabled }
}
/// No localized menu title, fixed menu index, OS/app version whitelist or injected keyboard fallback.
public enum ZoomMenuMatcher {
 public static func match(_ command: ZoomCommand, family: ApplicationFamily, items: [ZoomMenuItem]) -> Int? {
  let ids: Set<String> = command == .zoomIn ? ["zoomin:", "zoomin"] : command == .zoomOut ? ["zoomout:", "zoomout"] : ["actualsize:", "resetzoom:", "zoomreset"]
  let chars: Set<String> = command == .zoomIn ? ["+", "="] : command == .zoomOut ? ["-", "−"] : ["0"]
  let candidates = items.filter { item in
   guard item.enabled else { return false }
   if ids.contains(item.identifier?.lowercased() ?? "") { return true }
   guard family != .generic, family != .powerpoint, let modifiers = item.modifiers, modifiers == 0 || modifiers == 1 else { return false }
   return chars.contains(item.character ?? "")
  }
  return candidates.count == 1 ? candidates[0].token : nil
 }
}
/// Log-scale demand, at most two queued steps. Small corrections cancel net movement.
/// A sustained reversal of half a step drops pending whole steps in the old direction.
public struct DiscreteZoom {
 public let threshold = log(1.12), interval: UInt64 = 180_000_000
 public private(set) var demand: Double = 0
 private var submitted: UInt64?, reverseTravel: Double = 0
 public init() {}
 public mutating func add(logDelta: Double) {
  guard logDelta.isFinite, abs(logDelta) <= 1 else { return }
  if demand * logDelta < 0 {
   reverseTravel += abs(logDelta)
   if reverseTravel >= threshold / 2, hasStep { demand = demand.truncatingRemainder(dividingBy: threshold) }
  } else { reverseTravel = 0 }
  demand = max(-2 * threshold, min(2 * threshold, demand + logDelta))
 }
 public var hasStep: Bool { abs(demand) >= threshold }
 /// nil without a pending step; otherwise the part of `interval` not yet elapsed since the last take.
 public func delayUntilNextStep(now: UInt64) -> UInt64? {
  guard hasStep else { return nil }
  guard let submitted else { return 0 }
  guard now >= submitted else { return interval }
  return now - submitted >= interval ? 0 : interval - (now - submitted)
 }
 public mutating func take(now: UInt64) -> ZoomCommand? {
  guard hasStep, submitted.map({ now >= $0 && now - $0 >= interval }) ?? true else { return nil }
  let sign = demand > 0 ? 1.0 : -1.0; demand -= sign * threshold; submitted = now
  return sign > 0 ? .zoomIn : .zoomOut
 }
}
