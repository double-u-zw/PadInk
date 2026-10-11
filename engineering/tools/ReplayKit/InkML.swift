#if os(macOS)
import Foundation
import CoreGraphics

/// Minimal InkML trace decoder for what PowerPoint writes (ppt/ink/inkN.xml): channels from the
/// traceFormat, points separated by commas, values with sticky per-channel difference qualifiers
/// (`!` explicit, `'` first difference, `"` second difference; W3C InkML §4.2.1), signs acting as
/// separators ("24 65-225" is 24, 65, -225), `*` repeating the previous value.
public struct InkTrace: Equatable {
 public var points: [[Double]]           // one array of channel values per point
 public var xy: [CGPoint] { points.map { CGPoint(x: $0[0], y: $0.count > 1 ? $0[1] : 0) } }
}

public enum InkMLError: Error, Equatable { case malformed(String) }

public enum InkML {
 public static func traces(_ data: Data) throws -> [InkTrace] {
  guard let text = String(data: data, encoding: .utf8) else { throw InkMLError.malformed("utf8") }
  let channels = max(2, text.components(separatedBy: "<inkml:channel ").count - 1)
  var out = [InkTrace](); var cursor = text.startIndex
  // `<inkml:trace` followed by a space or `>`; never `<inkml:traceFormat`, `<inkml:traceGroup`, ...
  while let open = text.range(of: #"<inkml:trace[\s>]"#, options: .regularExpression, range: cursor..<text.endIndex) {
   guard let bodyStart = text.range(of: ">", range: text.index(before: open.upperBound)..<text.endIndex), let close = text.range(of: "</inkml:trace>", range: bodyStart.upperBound..<text.endIndex) else { throw InkMLError.malformed("trace") }
   out.append(InkTrace(points: try decode(String(text[bodyStart.upperBound..<close.lowerBound]), channels: channels)))
   cursor = close.upperBound
  }
  return out
 }

 enum Mode { case explicit, first, second }

 public static func decode(_ body: String, channels: Int) throws -> [[Double]] {
  var modes = Array(repeating: Mode.explicit, count: channels)
  var last = Array(repeating: 0.0, count: channels), velocity = Array(repeating: 0.0, count: channels)
  var points = [[Double]]()
  for rawPoint in body.split(separator: ",") {
   let tokens = try tokenize(String(rawPoint))
   guard !tokens.isEmpty else { continue }
   guard tokens.count <= channels else { throw InkMLError.malformed("too many values in point") }
   var point = last
   for (c, token) in tokens.enumerated() {
    if let q = token.qualifier { modes[c] = q }
    let value: Double
    if token.repeatPrevious { value = last[c] }
    else {
     switch modes[c] {
     case .explicit: value = token.number
     case .first: value = last[c] + token.number
     case .second: value = last[c] + velocity[c] + token.number
     }
    }
    velocity[c] = points.isEmpty ? 0 : value - last[c]
    point[c] = value
   }
   // Channels omitted at the end of a point keep their previous value.
   for c in tokens.count..<channels { velocity[c] = 0 }
   last = point; points.append(point)
  }
  return points
 }

 struct Token { var qualifier: Mode?; var number: Double; var repeatPrevious: Bool }
 static func tokenize(_ s: String) throws -> [Token] {
  var tokens = [Token](); var i = s.startIndex
  var qualifier: Mode? = nil, digits = ""
  func flush() throws {
   guard !digits.isEmpty else { return }
   guard let n = Double(digits) else { throw InkMLError.malformed("number \(digits)") }
   tokens.append(Token(qualifier: qualifier, number: n, repeatPrevious: false)); digits = ""; qualifier = nil
  }
  while i < s.endIndex {
   let c = s[i]
   switch c {
   case " ", "\n", "\t", "\r": try flush()
   case "!": try flush(); qualifier = .explicit
   case "'": try flush(); qualifier = .first
   case "\"": try flush(); qualifier = .second
   case "*": try flush(); tokens.append(Token(qualifier: qualifier, number: 0, repeatPrevious: true)); qualifier = nil
   case "-", "+": try flush(); digits = String(c)
   case "0"..."9", ".", "e", "E": digits.append(c)
   case "?": throw InkMLError.malformed("missing value")
   default: throw InkMLError.malformed("character \(c)")
   }
   i = s.index(after: i)
  }
  try flush()
  return tokens
 }
}

/// Reads the native ink parts of a .pptx (zip) with /usr/bin/unzip, in numeric part-name order. This is NOT creation order; use InkPlacement for comparisons.
public enum PPTXInk {
 public struct Part: Equatable { public let name: String; public let data: Data; public let traces: [InkTrace] }
 public static func parts(of pptx: URL) throws -> [Part] {
  let list = try run(["-Z1", pptx.path])
  let names = String(decoding: list, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.hasPrefix("ppt/ink/ink") && $0.hasSuffix(".xml") }
  let ordered = names.sorted { index($0) < index($1) }
  return try ordered.map { name in let data = try run(["-p", pptx.path, name]); return Part(name: name, data: data, traces: try InkML.traces(data)) }
 }
 static func index(_ name: String) -> Int { Int(name.dropFirst("ppt/ink/ink".count).dropLast(4)) ?? Int.max }
 static func run(_ args: [String]) throws -> Data {
  let p = Process(), out = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = args; p.standardOutput = out; p.standardError = Pipe()
  try p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
  guard p.terminationStatus == 0 else { throw InkMLError.malformed("unzip \(args.joined(separator: " ")) exit \(p.terminationStatus)") }
  return data
 }
}
#endif
