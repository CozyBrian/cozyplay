import XCTest

/// A TimelineMapping whose offset the test can slew, to simulate SyncClock's
/// applied-offset movement between chunks.
private final class SlewingClock: TimelineMapping {
    var isConverged = true
    var offsetNs: Int64 = 0    // host − local
    func localNs(fromHostNs hostNs: UInt64) -> UInt64 {
        UInt64(bitPattern: Int64(bitPattern: hostNs) - offsetNs)
    }
}

final class TimelinePlacerTests: XCTestCase {
    private let chunkNs: UInt64 = 20_000_000
    private let chunkFrames: Int64 = 960
    private let anchorNs: Int64 = 1_000_000_000

    private func place(
        _ placer: TimelinePlacer, _ clock: SlewingClock,
        stamp: UInt64, forceRemap: Bool = false
    ) -> TimelinePlacer.Result {
        let mapped = Int64(bitPattern: clock.localNs(fromHostNs: stamp))
        return placer.place(
            stampHostNs: stamp,
            mappedLocalNs: mapped,
            anchorNs: anchorNs,
            frameCount: Int(chunkFrames),
            forceRemap: forceRemap
        )
    }

    func testContiguousPlacementUnderClockSlew() {
        let placer = TimelinePlacer()
        let clock = SlewingClock()
        let start: UInt64 = 2_000_000_000

        var last = place(placer, clock, stamp: start)
        XCTAssertTrue(last.remapped)

        // Clock slews 20µs per chunk (the 1ms/s worst case) — placement must
        // stay EXACTLY 960 frames apart (this jitter was the crackle bug).
        for i in 1...100 {
            clock.offsetNs += 20_000
            let result = place(placer, clock, stamp: start + UInt64(i) * chunkNs)
            XCTAssertFalse(result.remapped, "chunk \(i) unexpectedly remapped")
            XCTAssertEqual(result.position, last.position + chunkFrames, "gap at chunk \(i)")
            last = result
        }
    }

    func testCorrectionSignTracksClockDrift() {
        let placer = TimelinePlacer()
        let clock = SlewingClock()
        let start: UInt64 = 2_000_000_000
        _ = place(placer, clock, stamp: start)

        // Offset grows ⇒ localNs(stamp) shrinks ⇒ clock says chunks should play
        // EARLIER (clockPos falls behind the contiguous positions). correction =
        // contiguous − clock must therefore grow POSITIVE, so the reader's
        // desired (which ADDS it) keeps chasing where the chunks actually are.
        var correction = 0.0
        for i in 1...200 {
            clock.offsetNs += 20_000
            correction = place(placer, clock, stamp: start + UInt64(i) * chunkNs).correctionFrames
        }
        // 200 chunks × 20µs = 4ms total drift ≈ 192 frames; EMA lags behind a
        // moving target, so just assert direction and rough magnitude.
        XCTAssertGreaterThan(correction, 50)
        XCTAssertLessThan(correction, 200)
    }

    func testSkippedChunksStayContiguous() {
        let placer = TimelinePlacer()
        let clock = SlewingClock()
        let start: UInt64 = 2_000_000_000
        let first = place(placer, clock, stamp: start)

        // Host skipped 3 chunks (slow-client policy): stamp jumps 4 intervals.
        let result = place(placer, clock, stamp: start + 4 * chunkNs)
        XCTAssertFalse(result.remapped, "k·20ms jump must stay contiguous")
        XCTAssertEqual(result.position, first.position + 4 * chunkFrames)
    }

    func testBufferIncreaseAliasedToChunkMultipleStaysAligned() {
        let placer = TimelinePlacer()
        let clock = SlewingClock()
        let start: UInt64 = 2_000_000_000
        var last = place(placer, clock, stamp: start)
        for i in 1...10 {
            last = place(placer, clock, stamp: start + UInt64(i) * chunkNs)
        }
        // Host buffer 150→250ms: next stamp is 20+100 = 120ms after the last.
        // Contiguous k=6 placement matches the clock's shift exactly, so no
        // remap, no correction step — the 100ms hole plays as silence.
        let result = place(placer, clock, stamp: start + 10 * chunkNs + 120_000_000)
        XCTAssertFalse(result.remapped)
        XCTAssertEqual(result.position, last.position + 6 * chunkFrames)
        XCTAssertEqual(result.correctionFrames, 0, accuracy: 1)
    }

    func testNonMultipleStampJumpRemaps() {
        let placer = TimelinePlacer()
        let clock = SlewingClock()
        let start: UInt64 = 2_000_000_000
        _ = place(placer, clock, stamp: start)

        // Assembler re-anchor: stamp jumps by 130ms (not a 20ms multiple ±1ms).
        let result = place(placer, clock, stamp: start + 130_000_000 + 5_000_000)
        XCTAssertTrue(result.remapped)
        XCTAssertEqual(result.correctionFrames, 0)
    }

    func testBackwardStampJumpRemaps() {
        let placer = TimelinePlacer()
        let clock = SlewingClock()
        let start: UInt64 = 2_000_000_000
        for i in 0...10 {
            _ = place(placer, clock, stamp: start + UInt64(i) * chunkNs)
        }
        // Buffer decrease: stamps go backward (k < 1) — must remap.
        let result = place(placer, clock, stamp: start + 10 * chunkNs - 80_000_000)
        XCTAssertTrue(result.remapped)
    }

    func testClockStepCaughtByDivergenceGuardWithoutFlag() {
        let placer = TimelinePlacer()
        let clock = SlewingClock()
        let start: UInt64 = 2_000_000_000
        let first = place(placer, clock, stamp: start)

        // Clock STEPS 50ms (host slept) with continuous stamps: even without
        // the hardResync flag the >4ms divergence guard must break the epoch.
        clock.offsetNs += 50_000_000
        let result = place(placer, clock, stamp: start + chunkNs)
        XCTAssertTrue(result.remapped)
        XCTAssertTrue(result.needsResync)
        XCTAssertEqual(result.correctionFrames, 0)
        // Position follows the stepped clock: 50ms ≈ 2400 frames earlier than
        // the contiguous continuation would have been.
        XCTAssertEqual(result.position, first.position + chunkFrames - 2400, accuracy: 2)
    }

    func testForceRemapBreaksContiguityBelowGuardThreshold() {
        let placer = TimelinePlacer()
        let clock = SlewingClock()
        let start: UInt64 = 2_000_000_000
        let first = place(placer, clock, stamp: start)

        // A 2ms mapping shift slips under the 4ms guard — without the flag it
        // is absorbed smoothly, with the flag it remaps immediately.
        clock.offsetNs += 2_000_000
        let withoutFlag = place(placer, clock, stamp: start + chunkNs)
        XCTAssertFalse(withoutFlag.remapped)
        XCTAssertEqual(withoutFlag.position, first.position + chunkFrames)

        clock.offsetNs += 2_000_000
        let withFlag = place(placer, clock, stamp: start + 2 * chunkNs, forceRemap: true)
        XCTAssertTrue(withFlag.remapped)
        XCTAssertEqual(withFlag.position, first.position + 2 * chunkFrames - 192, accuracy: 2)
    }
}

private func XCTAssertEqual(_ a: Int64, _ b: Int64, accuracy: Int64, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) != \(b) ± \(accuracy)", file: file, line: line)
}
