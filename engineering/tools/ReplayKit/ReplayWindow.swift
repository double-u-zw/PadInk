#if os(macOS)
import CoreGraphics

/// CGWindowList may put a pen tooltip or floating palette before the document, even at layer 0.
/// Use a substantial document window; equal-size windows retain front-to-back order.
public enum ReplayWindow {
 public static func documentBounds(in candidates: [CGRect]) -> CGRect? {
  var selected: CGRect?
  for bounds in candidates where bounds.width >= 320 && bounds.height >= 240 {
   if selected == nil || bounds.width * bounds.height > selected!.width * selected!.height {
    selected = bounds
   }
  }
  return selected
 }
}
#endif
