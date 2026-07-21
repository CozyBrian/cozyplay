import Foundation

/// Conversions between mach absolute time and nanoseconds.
///
/// All engine timestamps live in this clock domain (uptime nanoseconds as
/// `UInt64`) because `AudioTimeStamp.mHostTime` — the timestamp the capture
/// IOProc and the render callback receive — *is* `mach_absolute_time()`.
/// It is monotonic and never NTP-slewed; it pauses across sleep, which the
/// engine detects as a clock step and handles with a hard resync.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Current host uptime in nanoseconds.
    static func nowNs() -> UInt64 {
        ns(fromHostTicks: mach_absolute_time())
    }

    /// Convert mach ticks (e.g. `AudioTimeStamp.mHostTime`) to nanoseconds.
    static func ns(fromHostTicks ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// Convert nanoseconds back to mach ticks.
    static func hostTicks(fromNs ns: UInt64) -> UInt64 {
        ns * UInt64(timebase.denom) / UInt64(timebase.numer)
    }
}

/// Maps host-party timeline nanoseconds to local uptime nanoseconds.
/// `PlaybackEngine` renders against local time; each client owns one of these.
protocol TimelineMapping: AnyObject {
    /// True once the mapping is trustworthy enough to anchor playback on.
    var isConverged: Bool { get }
    func localNs(fromHostNs hostNs: UInt64) -> UInt64
}

/// The host's own mapping: party timeline time *is* local time.
final class IdentityClock: TimelineMapping {
    var isConverged: Bool { true }
    func localNs(fromHostNs hostNs: UInt64) -> UInt64 { hostNs }
}
