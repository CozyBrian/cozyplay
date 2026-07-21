import Foundation
import Accelerate

/// A timeline-indexed ring buffer of deinterleaved Float32 stereo frames.
///
/// Positions are *absolute frame indices* on the playback timeline (frame 0 =
/// the anchor instant); the ring index is `position & mask`. The writer (net
/// queue) converts S16LE chunks and writes them at their timeline position;
/// the reader (audio render thread) copies frames out and **zeroes the region
/// it has fully consumed** (via `zero(from:to:)` — kept separate from `read`
/// because the fractional-rate reader re-reads a couple of boundary frames) —
/// so data that never arrived renders as silence and playback self-heals with
/// no state machine in the render path.
///
/// Single writer + single reader. Positions cross threads through the C-shim
/// atomics; sample memory races only when reader and writer collide on a
/// region, which the position discipline (writer stays ahead of the reader by
/// the buffer delay) prevents in normal operation.
final class TimelineRingBuffer {
    /// 65,536 frames ≈ 1.37s @ 48kHz — comfortably above the max buffer setting.
    static let capacityFrames = 65_536

    private let mask = Int64(TimelineRingBuffer.capacityFrames - 1)
    private let channelCount = EngineConstants.channels
    private var channels: [UnsafeMutablePointer<Float>] = []
    private var scratch: [UnsafeMutablePointer<Float>] = []
    private let scratchCapacity = 8_192

    // Cross-thread positions and counters (see RTAtomics.h).
    private let readPositionStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let writeHeadStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let lateDropsStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let earlyDropsStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let writesOKStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    init() {
        for _ in 0..<channelCount {
            let channel = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacityFrames)
            channel.initialize(repeating: 0, count: Self.capacityFrames)
            channels.append(channel)
            let s = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
            s.initialize(repeating: 0, count: scratchCapacity)
            scratch.append(s)
        }
        readPositionStorage.initialize(to: 0)
        writeHeadStorage.initialize(to: 0)
        lateDropsStorage.initialize(to: 0)
        earlyDropsStorage.initialize(to: 0)
        writesOKStorage.initialize(to: 0)
    }

    deinit {
        channels.forEach { $0.deallocate() }
        scratch.forEach { $0.deallocate() }
        readPositionStorage.deallocate()
        writeHeadStorage.deallocate()
        lateDropsStorage.deallocate()
        earlyDropsStorage.deallocate()
        writesOKStorage.deallocate()
    }

    // MARK: Positions

    /// Next frame the render thread will consume. Written by the reader,
    /// read by the writer (late-chunk dropping) and diagnostics.
    var readPosition: Int64 {
        get { rt_atomic_load(readPositionStorage) }
        set { rt_atomic_store(readPositionStorage, newValue) }
    }

    /// Highest timeline position written so far (exclusive).
    private(set) var writeHead: Int64 {
        get { rt_atomic_load(writeHeadStorage) }
        set { rt_atomic_store(writeHeadStorage, newValue) }
    }

    /// Frames of real audio ahead of the reader (diagnostics).
    var bufferedFrames: Int64 { max(0, writeHead - readPosition) }

    // Diagnostics counters.
    var lateDrops: Int64 { rt_atomic_load(lateDropsStorage) }
    var earlyDrops: Int64 { rt_atomic_load(earlyDropsStorage) }
    var writesOK: Int64 { rt_atomic_load(writesOKStorage) }

    /// Reset positions and silence the ring (anchor change / reconnect).
    /// Caller must guarantee the render thread is not mid-read (engine stopped).
    func reset() {
        for channel in channels {
            vDSP_vclr(channel, 1, vDSP_Length(Self.capacityFrames))
        }
        readPosition = 0
        writeHead = 0
    }

    // MARK: Writer (net queue)

    /// Convert interleaved S16LE bytes and write them at `position`.
    /// Chunks entirely behind the reader are dropped (too late); positions
    /// unreasonably far ahead are dropped (protects unread data).
    @discardableResult
    func write(samplesS16 data: Data, at position: Int64) -> Bool {
        let frames = data.count / EngineConstants.bytesPerFrame
        guard frames > 0, frames <= scratchCapacity else { return false }

        let readPos = readPosition
        if position + Int64(frames) <= readPos {                          // fully late
            _ = rt_atomic_add(lateDropsStorage, 1)
            return false
        }
        if position - readPos > Int64(Self.capacityFrames - frames) {     // absurdly early
            _ = rt_atomic_add(earlyDropsStorage, 1)
            return false
        }

        // Deinterleave + scale S16 → Float32 into scratch.
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let int16Ptr = raw.bindMemory(to: Int16.self).baseAddress!
            var scale = Float(1.0 / 32768.0)
            for ch in 0..<channelCount {
                vDSP_vflt16(int16Ptr + ch, vDSP_Stride(channelCount), scratch[ch], 1, vDSP_Length(frames))
                vDSP_vsmul(scratch[ch], 1, &scale, scratch[ch], 1, vDSP_Length(frames))
            }
        }

        copyIntoRing(from: scratch, at: position, frames: frames)
        if position + Int64(frames) > writeHead {
            writeHead = position + Int64(frames)
        }
        _ = rt_atomic_add(writesOKStorage, 1)
        return true
    }

    private func copyIntoRing(from source: [UnsafeMutablePointer<Float>], at position: Int64, frames: Int) {
        let start = Int(position & mask)
        let firstSegment = min(frames, Self.capacityFrames - start)
        let secondSegment = frames - firstSegment
        for ch in 0..<channelCount {
            channels[ch].advanced(by: start).update(from: source[ch], count: firstSegment)
            if secondSegment > 0 {
                channels[ch].update(from: source[ch].advanced(by: firstSegment), count: secondSegment)
            }
        }
    }

    // MARK: Reader (render thread — RT-safe: no locks, no allocation)

    /// Copy `frames` frames starting at `position` into the (non-interleaved
    /// Float32) destination pointers. Does NOT zero — call `zero(from:to:)`
    /// for the fully-consumed range afterwards.
    func read(
        into destinations: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>?>,
        from position: Int64,
        frames: Int
    ) {
        guard frames <= Self.capacityFrames else { return }
        let start = Int(position & mask)
        let firstSegment = min(frames, Self.capacityFrames - start)
        let secondSegment = frames - firstSegment
        for ch in 0..<channelCount where ch < destinations.count {
            guard let dst = destinations[ch] else { continue }
            dst.update(from: channels[ch].advanced(by: start), count: firstSegment)
            if secondSegment > 0 {
                dst.advanced(by: firstSegment).update(from: channels[ch], count: secondSegment)
            }
        }
    }

    /// Silence the timeline range `[from, to)` (consumed or skipped regions).
    /// RT-safe. Ranges wider than the ring clear the whole ring.
    func zero(from: Int64, to: Int64) {
        guard to > from else { return }
        let count = Int(min(to - from, Int64(Self.capacityFrames)))
        let start = Int(from & mask)
        let firstSegment = min(count, Self.capacityFrames - start)
        let secondSegment = count - firstSegment
        for ch in 0..<channelCount {
            vDSP_vclr(channels[ch].advanced(by: start), 1, vDSP_Length(firstSegment))
            if secondSegment > 0 {
                vDSP_vclr(channels[ch], 1, vDSP_Length(secondSegment))
            }
        }
    }
}
