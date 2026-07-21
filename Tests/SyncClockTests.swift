import XCTest

/// Deterministic time for SyncClock: the test controls "local now" and the
/// simulated true host−local offset and one-way delays.
private final class FakeTime {
    var now: UInt64 = 10_000_000_000    // start at 10s of uptime

    func advance(ms: Double) { now += UInt64(ms * 1e6) }
}

private func makeClock(_ time: FakeTime) -> SyncClock {
    SyncClock(now: { time.now })
}

/// Simulate one full ping/pong exchange.
/// - Parameters:
///   - offsetMs: true offset (host clock − local clock)
///   - d1Ms/d2Ms: one-way network delays client→host / host→client
private func exchange(
    _ clock: SyncClock, _ time: FakeTime,
    offsetMs: Double, d1Ms: Double, d2Ms: Double, hostProcMs: Double = 0.1
) {
    let offset = Int64(offsetMs * 1e6)
    let t0 = clock.makePingT0()
    let t1 = UInt64(Int64(t0) + Int64(d1Ms * 1e6) + offset)
    let t2 = t1 + UInt64(hostProcMs * 1e6)
    time.now = t0 + UInt64((d1Ms + hostProcMs + d2Ms) * 1e6)
    clock.ingestPong(t0: t0, t1: t1, t2: t2)
}

/// The offset the clock is currently applying, recovered through the public mapping.
private func appliedOffsetMs(_ clock: SyncClock, _ time: FakeTime) -> Double {
    let hostNs = time.now + 500_000_000    // arbitrary future host timestamp
    let localNs = clock.localNs(fromHostNs: hostNs)
    return (Double(hostNs) - Double(localNs)) / 1e6
}

final class SyncClockTests: XCTestCase {

    func testSymmetricDelaysRecoverExactOffset() {
        let time = FakeTime()
        let clock = makeClock(time)
        for _ in 0..<8 {
            exchange(clock, time, offsetMs: 123.456, d1Ms: 2, d2Ms: 2)
            time.advance(ms: 1000)
        }
        XCTAssertTrue(clock.isConverged)
        XCTAssertEqual(clock.diagnostics.offsetMs, 123.456, accuracy: 0.001)
        XCTAssertEqual(appliedOffsetMs(clock, time), 123.456, accuracy: 0.001)
    }

    func testNegativeOffset() {
        let time = FakeTime()
        let clock = makeClock(time)
        for _ in 0..<8 {
            exchange(clock, time, offsetMs: -77.5, d1Ms: 1.5, d2Ms: 1.5)
            time.advance(ms: 1000)
        }
        XCTAssertTrue(clock.isConverged)
        XCTAssertEqual(clock.diagnostics.offsetMs, -77.5, accuracy: 0.001)
    }

    func testAsymmetricDelaySpikesAreRejected() {
        let time = FakeTime()
        let clock = makeClock(time)
        for _ in 0..<10 {
            exchange(clock, time, offsetMs: 50, d1Ms: 1.5, d2Ms: 1.5)
            time.advance(ms: 1000)
        }
        // WiFi retransmit spikes: hugely asymmetric, offset estimate off by ~40ms,
        // but RTT is inflated too — the gate must discard them.
        for _ in 0..<5 {
            exchange(clock, time, offsetMs: 50, d1Ms: 80, d2Ms: 2)
            time.advance(ms: 1000)
        }
        XCTAssertTrue(clock.isConverged)
        XCTAssertEqual(clock.diagnostics.offsetMs, 50, accuracy: 0.1)
    }

    func testConvergenceRequiresFiveCleanSamples() {
        let time = FakeTime()
        let clock = makeClock(time)
        for i in 1...6 {
            exchange(clock, time, offsetMs: 10, d1Ms: 2, d2Ms: 2)
            time.advance(ms: 50)
            if i < 5 {
                XCTAssertFalse(clock.isConverged, "converged after only \(i) samples")
            } else {
                XCTAssertTrue(clock.isConverged, "not converged after \(i) samples")
            }
        }
    }

    func testClockStepFiresDesyncAndSnaps() {
        let time = FakeTime()
        let clock = makeClock(time)
        var desyncs = 0
        clock.onDesync = { desyncs += 1 }

        for _ in 0..<10 {
            exchange(clock, time, offsetMs: 0, d1Ms: 2, d2Ms: 2)
            time.advance(ms: 1000)
        }
        XCTAssertTrue(clock.isConverged)

        // Host slept: true offset jumps by 50ms. Needs 3 clean confirmations.
        exchange(clock, time, offsetMs: 50, d1Ms: 2, d2Ms: 2)
        time.advance(ms: 1000)
        XCTAssertEqual(desyncs, 0)
        exchange(clock, time, offsetMs: 50, d1Ms: 2, d2Ms: 2)
        time.advance(ms: 1000)
        XCTAssertEqual(desyncs, 0)
        exchange(clock, time, offsetMs: 50, d1Ms: 2, d2Ms: 2)
        XCTAssertEqual(desyncs, 1)

        // Applied immediately (snapped, not slewed).
        XCTAssertEqual(appliedOffsetMs(clock, time), 50, accuracy: 0.5)
    }

    func testSpikesDoNotTriggerStepDetection() {
        let time = FakeTime()
        let clock = makeClock(time)
        var desyncs = 0
        clock.onDesync = { desyncs += 1 }

        for _ in 0..<10 {
            exchange(clock, time, offsetMs: 0, d1Ms: 2, d2Ms: 2)
            time.advance(ms: 1000)
        }
        // Big offset errors with big RTTs: congested WiFi, not a clock step.
        for _ in 0..<6 {
            exchange(clock, time, offsetMs: 0, d1Ms: 100, d2Ms: 2)
            time.advance(ms: 1000)
        }
        XCTAssertEqual(desyncs, 0)
        XCTAssertEqual(clock.diagnostics.offsetMs, 0, accuracy: 0.1)
    }

    func testSmallShiftSlewsAtOneMillisecondPerSecond() {
        let time = FakeTime()
        let clock = makeClock(time)
        // Converge at 0 with 1.5ms one-way delay.
        for _ in 0..<10 {
            exchange(clock, time, offsetMs: 0, d1Ms: 1.5, d2Ms: 1.5)
            time.advance(ms: 1000)
        }
        XCTAssertEqual(appliedOffsetMs(clock, time), 0, accuracy: 0.05)

        // Estimate shifts by +5ms (below the 20ms step threshold). New samples get
        // slightly lower RTT so they immediately dominate the best-5 selection.
        for i in 1...7 {
            exchange(clock, time, offsetMs: 5, d1Ms: 1.2, d2Ms: 1.2)
            let applied = appliedOffsetMs(clock, time)
            let expected = min(5.0, Double(i))    // ≤1ms per elapsed second
            XCTAssertLessThanOrEqual(
                applied, expected + 0.1,
                "slewed too fast at second \(i): \(applied)ms"
            )
            time.advance(ms: 1000)
        }
        // After 7s the full 5ms shift should be applied.
        XCTAssertEqual(appliedOffsetMs(clock, time), 5, accuracy: 0.2)
    }

    func testMalformedPongIsIgnored() {
        let time = FakeTime()
        let clock = makeClock(time)
        for _ in 0..<6 {
            exchange(clock, time, offsetMs: 5, d1Ms: 2, d2Ms: 2)
            time.advance(ms: 1000)
        }
        let before = clock.diagnostics
        // t2 < t1 (host timestamps reversed) and t3 < t0 shapes must be discarded.
        clock.ingestPong(t0: time.now, t1: 100, t2: 50)
        clock.ingestPong(t0: time.now + 1_000_000_000, t1: time.now, t2: time.now)
        XCTAssertEqual(clock.diagnostics.samples, before.samples)
    }

    func testResetClearsState() {
        let time = FakeTime()
        let clock = makeClock(time)
        for _ in 0..<6 {
            exchange(clock, time, offsetMs: 5, d1Ms: 2, d2Ms: 2)
            time.advance(ms: 1000)
        }
        XCTAssertTrue(clock.isConverged)
        clock.reset()
        XCTAssertFalse(clock.isConverged)
        XCTAssertEqual(clock.diagnostics.samples, 0)
    }
}
