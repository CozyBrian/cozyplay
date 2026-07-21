import Foundation

/// Client-side estimate of the mapping between the host's uptime clock and ours.
///
/// NTP-style: we stamp `t0` when a ping leaves, the host stamps `t1` (receive)
/// and `t2` (send), we stamp `t3` when the pong lands.
/// ```
///   offset = ((t1−t0) + (t2−t3)) / 2      // host − local
///   rtt    = (t3−t0) − (t2−t1)
/// ```
/// Samples inflated by queueing or WiFi retransmits are discarded by a min-RTT
/// gate; the estimate is the median of the lowest-RTT survivors. The *applied*
/// offset slews toward the estimate at ≤1ms/s so playback never sees a step.
/// A genuine step (host slept, network change: >20ms, confirmed by 3
/// consecutive clean samples) is applied immediately and signalled via
/// `onDesync` so playback can hard-resync.
///
/// Not thread-safe: confine to one queue (the client's network queue).
final class SyncClock: TimelineMapping {
    private struct Sample {
        let at: UInt64      // local ns when the pong landed (t3)
        let offset: Int64   // host − local, ns
        let rtt: UInt64     // ns
    }

    /// Fired when a confirmed clock step was applied (playback should hard-resync).
    var onDesync: (() -> Void)?

    private let now: () -> UInt64
    private var window: [Sample] = []
    private var stepSuspects: [Sample] = []

    // Slew state: applied offset accrues from (slewBase, slewBaseAt) toward the target.
    private var haveApplied = false
    private var slewBase: Int64 = 0
    private var slewBaseAt: UInt64 = 0

    private let windowSize = 32
    private let medianCount = 5
    private let rttGateSlackNs: UInt64 = 500_000          // gate = 1.5×minRTT + 0.5ms
    private let stepThresholdNs: Int64 = 20_000_000       // 20ms
    private let stepConfirmCount = 3
    private let maxSlewNsPerSec: Int64 = 1_000_000        // 1ms/s
    private let convergenceSpreadNs: Int64 = 1_000_000    // 1ms

    init(now: @escaping () -> UInt64 = HostClock.nowNs) {
        self.now = now
    }

    // MARK: Ping/pong

    /// Stamp t0 for an outgoing ping.
    func makePingT0() -> UInt64 { now() }

    /// Ingest a pong; stamps t3 internally.
    func ingestPong(t0: UInt64, t1: UInt64, t2: UInt64) {
        let t3 = now()
        guard t3 >= t0, t2 >= t1, (t3 - t0) >= (t2 - t1) else { return }  // malformed/reordered
        let rtt = (t3 - t0) - (t2 - t1)
        let offset = (Int64(bitPattern: t1 &- t0) &+ Int64(bitPattern: t2 &- t3)) / 2
        let sample = Sample(at: t3, offset: offset, rtt: rtt)

        // Clock-step detection: several consecutive samples that pass the RTT
        // gate yet sit far from the estimate mean the mapping itself moved
        // (sleep/wake), not noise. Withhold them from the window until confirmed.
        if let target = targetOffset(), abs(offset - target) > stepThresholdNs {
            if passesRttGate(sample) {
                stepSuspects.append(sample)
                if stepSuspects.count >= stepConfirmCount {
                    window = stepSuspects
                    stepSuspects = []
                    if let stepped = targetOffset() {
                        slewBase = stepped
                        slewBaseAt = t3
                        onDesync?()
                    }
                }
            }
            return
        }
        stepSuspects = []

        window.append(sample)
        if window.count > windowSize {
            window.removeFirst(window.count - windowSize)
        }

        // Rebase the slew so the applied offset keeps accruing from "here".
        if let target = targetOffset() {
            if haveApplied {
                slewBase = appliedOffset(at: t3)
                slewBaseAt = t3
            } else if isConverged {
                slewBase = target
                slewBaseAt = t3
                haveApplied = true
            }
        }
    }

    /// Drop all state (reconnect, role change).
    func reset() {
        window = []
        stepSuspects = []
        haveApplied = false
    }

    // MARK: TimelineMapping

    var isConverged: Bool {
        let best = bestSamples()
        guard best.count >= medianCount else { return false }
        let offsets = best.map(\.offset)
        return offsets.max()! - offsets.min()! < convergenceSpreadNs
    }

    func localNs(fromHostNs hostNs: UInt64) -> UInt64 {
        let offset = haveApplied ? appliedOffset(at: now()) : (targetOffset() ?? 0)
        return UInt64(bitPattern: Int64(bitPattern: hostNs) &- offset)
    }

    // MARK: Diagnostics

    /// (median offset, min RTT in window, accepted sample count) — for logging/HUD.
    var diagnostics: (offsetMs: Double, minRttMs: Double, samples: Int, converged: Bool) {
        let offset = targetOffset() ?? 0
        let minRtt = window.map(\.rtt).min() ?? 0
        return (Double(offset) / 1e6, Double(minRtt) / 1e6, acceptedSamples().count, isConverged)
    }

    /// Estimated local-vs-host clock drift (ns per second) over the accepted
    /// window — diagnostic only; the playback servo absorbs real drift.
    var estimatedDriftNsPerSec: Double? {
        let accepted = acceptedSamples()
        guard let first = accepted.first, let last = accepted.last,
              last.at - first.at >= 30_000_000_000 else { return nil }
        let xs = accepted.map { Double($0.at - first.at) / 1e9 }
        let ys = accepted.map { Double($0.offset) }
        let n = Double(xs.count)
        let xMean = xs.reduce(0, +) / n
        let yMean = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - xMean) * (y - yMean)
            den += (x - xMean) * (x - xMean)
        }
        guard den > 0 else { return nil }
        return max(-300_000, min(300_000, num / den))    // clamp ±300ppm
    }

    // MARK: Internals

    private func passesRttGate(_ sample: Sample) -> Bool {
        guard let minRtt = window.map(\.rtt).min() else { return true }
        return sample.rtt <= minRtt + minRtt / 2 + rttGateSlackNs
    }

    private func acceptedSamples() -> [Sample] {
        guard let minRtt = window.map(\.rtt).min() else { return [] }
        let gate = minRtt + minRtt / 2 + rttGateSlackNs
        return window.filter { $0.rtt <= gate }
    }

    /// The `medianCount` lowest-RTT accepted samples.
    private func bestSamples() -> [Sample] {
        Array(acceptedSamples().sorted { $0.rtt < $1.rtt }.prefix(medianCount))
    }

    private func targetOffset() -> Int64? {
        let best = bestSamples()
        guard !best.isEmpty else { return nil }
        return best.map(\.offset).sorted()[best.count / 2]
    }

    private func appliedOffset(at t: UInt64) -> Int64 {
        let target = targetOffset() ?? slewBase
        let dt = t > slewBaseAt ? Int64(t - slewBaseAt) : 0
        let maxDelta = maxSlewNsPerSec * (dt / 1_000_000) / 1_000
        let want = target - slewBase
        return slewBase + max(-maxDelta, min(maxDelta, want))
    }
}
