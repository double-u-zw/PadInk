import Foundation

/// Local monotonic nanoseconds (mach uptime). The only clock used for liveness, freshness and
/// timers. Baseline called this `Clock`, which shadows Swift's `Clock` protocol.
public enum MonotonicClock {
 public static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
}
