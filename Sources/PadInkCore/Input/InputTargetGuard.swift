/// A target revision is captured at contact start. Delayed notifications for that same revision
/// cannot cancel a new stroke; a genuine target change cancels exactly the current gesture.
public struct InputTargetGuard {
 public private(set) var contact: (gesture: UInt64, revision: UInt64)?
 public init() {}
 public mutating func began(_ gesture: UInt64, revision: UInt64) { contact = (gesture, revision) }
 public mutating func ended() { contact = nil }
 public mutating func changed(to revision: UInt64) -> UInt64? {
  guard let contact, contact.revision != revision else { return nil }
  self.contact = nil; return contact.gesture
 }
}
