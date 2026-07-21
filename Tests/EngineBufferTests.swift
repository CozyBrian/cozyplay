import XCTest

final class ChunkAssemblerTests: XCTestCase {
    private let bytesPerFrame = EngineConstants.bytesPerFrame
    private let chunkFrames = EngineConstants.chunkFrames

    private func block(frames: Int, fill: UInt8 = 0xAB) -> Data {
        Data(repeating: fill, count: frames * bytesPerFrame)
    }

    private func ns(afterFrames frames: Int, from start: UInt64) -> UInt64 {
        start + UInt64(Double(frames) * 1e9 / Double(EngineConstants.sampleRate))
    }

    func testAccumulatesExactChunksWithContinuousTimestamps() {
        let assembler = ChunkAssembler()
        let start: UInt64 = 5_000_000_000
        var emitted: [ChunkAssembler.Chunk] = []
        // 4 × 480 frames = 2 chunks of 960.
        for i in 0..<4 {
            emitted += assembler.ingest(
                block(frames: 480),
                firstFrameHostNs: ns(afterFrames: i * 480, from: start)
            )
        }
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted.map(\.seq), [0, 1])
        XCTAssertEqual(emitted[0].captureNs, start)
        XCTAssertEqual(emitted[0].samples.count, EngineConstants.chunkBytes)
        // Chunks must be exactly 20ms apart (sample-continuous stamping).
        let delta = Int64(emitted[1].captureNs) - Int64(emitted[0].captureNs)
        XCTAssertEqual(delta, 20_000_000, accuracy: 1)
    }

    func testTimestampJitterDoesNotGapChunks() {
        let assembler = ChunkAssembler()
        let start: UInt64 = 5_000_000_000
        var emitted: [ChunkAssembler.Chunk] = []
        // ±40µs of IOProc timestamp jitter must not appear in chunk stamps.
        for i in 0..<40 {
            let jitter = Int64((i % 2 == 0) ? 40_000 : -40_000)
            let stamped = UInt64(Int64(ns(afterFrames: i * 480, from: start)) + jitter)
            emitted += assembler.ingest(block(frames: 480), firstFrameHostNs: stamped)
        }
        XCTAssertEqual(emitted.count, 20)
        for pair in zip(emitted, emitted.dropFirst()) {
            let delta = Int64(pair.1.captureNs) - Int64(pair.0.captureNs)
            // Exactly 20ms ± the max anchor slew of one ingest call (10µs).
            XCTAssertEqual(delta, 20_000_000, accuracy: 10_001, "gap between seq \(pair.0.seq)/\(pair.1.seq)")
        }
    }

    func testDiscontinuityReanchorsAndDropsPartial() {
        let assembler = ChunkAssembler()
        let start: UInt64 = 5_000_000_000
        // Half a chunk, then a 500ms gap (tap restarted).
        _ = assembler.ingest(block(frames: 480, fill: 0x01), firstFrameHostNs: start)
        let resumed = start + 500_000_000
        var emitted = assembler.ingest(block(frames: 480, fill: 0x02), firstFrameHostNs: resumed)
        XCTAssertTrue(emitted.isEmpty, "stale partial chunk must be dropped on re-anchor")
        emitted = assembler.ingest(
            block(frames: 480, fill: 0x02),
            firstFrameHostNs: ns(afterFrames: 480, from: resumed)
        )
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].captureNs, resumed)
        // The emitted chunk must contain only post-gap audio.
        XCTAssertEqual(emitted[0].samples.first, 0x02)
    }

    func testSequenceSurvivesReanchor() {
        let assembler = ChunkAssembler()
        var emitted = assembler.ingest(block(frames: 960), firstFrameHostNs: 1_000_000_000)
        emitted += assembler.ingest(block(frames: 960), firstFrameHostNs: 9_000_000_000)
        XCTAssertEqual(emitted.map(\.seq), [0, 1], "seq is monotonic across re-anchors")
    }
}

final class TimelineRingBufferTests: XCTestCase {

    /// Interleaved S16 data where left channel = `value`, right = `-value`.
    private func s16Frames(_ count: Int, value: Int16) -> Data {
        var data = Data(capacity: count * 4)
        for _ in 0..<count {
            data.appendLE(UInt16(bitPattern: value))
            data.appendLE(UInt16(bitPattern: -value))
        }
        return data
    }

    private func readFrames(_ ring: TimelineRingBuffer, from position: Int64, count: Int) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: .nan, count: count)
        var right = [Float](repeating: .nan, count: count)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                let dsts = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
                defer { dsts.deallocate() }
                dsts[0] = l.baseAddress
                dsts[1] = r.baseAddress
                ring.read(into: UnsafeMutableBufferPointer(start: dsts, count: 2), from: position, frames: count)
            }
        }
        return (left, right)
    }

    func testWriteReadRoundTripDeinterleavedAndScaled() {
        let ring = TimelineRingBuffer()
        XCTAssertTrue(ring.write(samplesS16: s16Frames(960, value: 16384), at: 0))
        let out = readFrames(ring, from: 0, count: 960)
        XCTAssertEqual(out.left[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(out.right[0], -0.5, accuracy: 0.0001)
        XCTAssertEqual(out.left[959], 0.5, accuracy: 0.0001)
    }

    func testReadZeroesConsumedRegion() {
        let ring = TimelineRingBuffer()
        ring.write(samplesS16: s16Frames(960, value: 16384), at: 0)
        _ = readFrames(ring, from: 0, count: 960)
        let second = readFrames(ring, from: 0, count: 960)
        XCTAssertEqual(second.left[0], 0)
        XCTAssertEqual(second.right[500], 0)
    }

    func testWrapAroundWriteAndRead() {
        let ring = TimelineRingBuffer()
        let capacity = Int64(TimelineRingBuffer.capacityFrames)
        // Straddle the ring boundary: start 100 frames before wrap.
        let position = capacity - 100
        ring.readPosition = position    // keep the writer's early/late checks happy
        XCTAssertTrue(ring.write(samplesS16: s16Frames(960, value: 8192), at: position))
        let out = readFrames(ring, from: position, count: 960)
        XCTAssertEqual(out.left[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(out.left[99], 0.25, accuracy: 0.0001)
        XCTAssertEqual(out.left[100], 0.25, accuracy: 0.0001)   // first frame past the wrap
        XCTAssertEqual(out.left[959], 0.25, accuracy: 0.0001)
        XCTAssertEqual(out.right[959], -0.25, accuracy: 0.0001)
    }

    func testLateChunkIsDropped() {
        let ring = TimelineRingBuffer()
        ring.readPosition = 10_000
        XCTAssertFalse(ring.write(samplesS16: s16Frames(960, value: 100), at: 9_000))
        // Partially late is still written (its tail is playable).
        XCTAssertTrue(ring.write(samplesS16: s16Frames(960, value: 100), at: 9_500))
    }

    func testAbsurdlyEarlyChunkIsDropped() {
        let ring = TimelineRingBuffer()
        ring.readPosition = 0
        let tooFar = Int64(TimelineRingBuffer.capacityFrames)   // would clobber unread data
        XCTAssertFalse(ring.write(samplesS16: s16Frames(960, value: 100), at: tooFar))
    }

    func testNeverWrittenRegionReadsSilence() {
        let ring = TimelineRingBuffer()
        let out = readFrames(ring, from: 12_345, count: 512)
        XCTAssertTrue(out.left.allSatisfy { $0 == 0 })
        XCTAssertTrue(out.right.allSatisfy { $0 == 0 })
    }
}
