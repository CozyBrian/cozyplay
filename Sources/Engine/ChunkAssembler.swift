import Foundation

/// Accumulates converted S16LE audio into exact `EngineConstants.chunkFrames`
/// chunks with **sample-continuous capture timestamps**.
///
/// Chunk timestamps must advance by exactly 20ms per chunk — if each chunk were
/// stamped straight from its IOProc `mHostTime`, timestamp jitter would gap or
/// overlap adjacent chunks by a few samples on the client ring (a click every
/// 20ms). So chunks are stamped from an anchor extrapolated at the nominal
/// rate, and the anchor is *slewed* gently toward the observed capture clock
/// (the aggregate device's clock drifts vs. mach time by ~±100ppm, which would
/// otherwise accumulate without bound).
///
/// Not thread-safe: confine to the tap IO queue.
final class ChunkAssembler {
    struct Chunk {
        let seq: UInt32
        /// Host time (ns) of the chunk's first frame at capture.
        let captureNs: UInt64
        /// Interleaved S16LE bytes, exactly `EngineConstants.chunkBytes`.
        let samples: Data
    }

    private var pending = Data()
    private var anchorNs: Int64 = 0
    private var emittedFrames: Int64 = 0    // frames emitted as chunks since anchor
    private var hasAnchor = false
    private var seq: UInt32 = 0

    private let nsPerFrame = 1_000_000_000.0 / Double(EngineConstants.sampleRate)
    /// A gap/jump this large means the capture stream restarted — re-anchor.
    private let reanchorThresholdNs: Int64 = 50_000_000       // 50ms
    /// Max anchor correction per ingest call (~50–100 calls/s ⇒ ≤1ms/s of slew,
    /// comfortably above real device-vs-mach drift).
    private let maxSlewPerCallNs: Int64 = 10_000

    private var pendingFrames: Int64 { Int64(pending.count / EngineConstants.bytesPerFrame) }

    /// Ingest converted audio whose first frame was captured at `firstFrameHostNs`.
    /// Returns zero or more completed chunks.
    func ingest(_ data: Data, firstFrameHostNs: UInt64) -> [Chunk] {
        guard !data.isEmpty else { return [] }

        if hasAnchor {
            let expectedNs = anchorNs + Int64(Double(emittedFrames + pendingFrames) * nsPerFrame)
            let err = Int64(bitPattern: firstFrameHostNs) - expectedNs
            if abs(err) > reanchorThresholdNs {
                // Capture discontinuity (tap restart, machine slept): drop the
                // partial chunk and restart the timeline here.
                pending.removeAll(keepingCapacity: true)
                anchorNs = Int64(bitPattern: firstFrameHostNs)
                emittedFrames = 0
            } else {
                anchorNs += max(-maxSlewPerCallNs, min(maxSlewPerCallNs, err / 64))
            }
        } else {
            anchorNs = Int64(bitPattern: firstFrameHostNs)
            emittedFrames = 0
            hasAnchor = true
        }

        pending.append(data)

        var chunks: [Chunk] = []
        let chunkBytes = EngineConstants.chunkBytes
        while pending.count >= chunkBytes {
            let captureNs = UInt64(bitPattern: anchorNs + Int64(Double(emittedFrames) * nsPerFrame))
            chunks.append(Chunk(
                seq: seq,
                captureNs: captureNs,
                samples: Data(pending.prefix(chunkBytes))
            ))
            seq &+= 1
            emittedFrames += Int64(EngineConstants.chunkFrames)
            pending.removeFirst(chunkBytes)
        }
        return chunks
    }

    /// Drop any partial chunk (stop/teardown).
    func flush() {
        pending.removeAll(keepingCapacity: true)
        hasAnchor = false
        emittedFrames = 0
    }
}
