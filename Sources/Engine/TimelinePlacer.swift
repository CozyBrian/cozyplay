import Foundation

/// Decides the ring position for each incoming chunk.
///
/// Mapping every chunk through the clock independently would jitter positions
/// by ±1 frame whenever the clock's applied offset (or the host's capture
/// anchor) slews — a sample skip/repeat at up to chunk rate, audible as
/// crackle. Instead: while the host stamps are continuous (exact multiples of
/// the 20ms chunk interval), chunks are placed **contiguously** — and the
/// slowly-drifting difference between the contiguous timeline and the clock's
/// opinion is exported as a smoothed `correctionFrames` that the reader ADDS
/// to its servo target, absorbing the drift by resampling instead of clicks.
///
/// Worst-case correction slope = clock slew (1ms/s) + host capture-anchor slew
/// (1ms/s) = 2ms/s — exactly the servo's ±2000ppm ratio clamp; real drift is
/// far smaller.
///
/// Not thread-safe: confine to the client's net queue.
final class TimelinePlacer {
    struct Result {
        /// Ring position for the chunk's first frame.
        var position: Int64
        /// Position came from a fresh clock mapping (epoch break).
        var remapped: Bool
        /// Stamp pathology detected — the reader should hard-resync.
        var needsResync: Bool
        /// Smoothed (contiguous − clock) offset in frames; reader adds this
        /// to its servo target.
        var correctionFrames: Double
    }

    private let framesPerNs = Double(EngineConstants.sampleRate) / 1e9
    private let chunkStampNs = Int64(EngineConstants.chunkFrames) * 1_000_000_000
        / Int64(EngineConstants.sampleRate)                       // 20ms
    private let chunkFrames = Int64(EngineConstants.chunkFrames)

    private var lastStampNs: UInt64 = 0
    private var lastPos: Int64 = 0
    private var lastFrames: Int64 = 0
    private var hasLast = false
    private var correctionEma: Double = 0

    private let emaAlpha = 0.08                                   // ~0.25s time constant at 50 chunks/s
    private let residualToleranceNs: Int64 = 1_000_000            // stamps must be k·20ms ± 1ms
    private let maxContiguousSkipChunks: Int64 = 50               // gaps > 1s start a fresh epoch
    private let divergenceGuardFrames = 4.0 * 48                  // 4ms: stamp pathology → remap

    /// - Parameters:
    ///   - stampHostNs: the chunk's play-at time in the host clock domain.
    ///   - mappedLocalNs: that stamp mapped through the clock (local ns).
    ///   - anchorNs: the playback anchor (local ns of ring position 0).
    ///   - forceRemap: break contiguity (clock step, device change): the
    ///     stamps stay continuous across a clock step — only the mapping
    ///     moved — so without this the placer would sail through the step
    ///     and drag the correction for tens of seconds.
    func place(
        stampHostNs: UInt64,
        mappedLocalNs: Int64,
        anchorNs: Int64,
        frameCount: Int,
        forceRemap: Bool
    ) -> Result {
        let clockPos = Double(mappedLocalNs - anchorNs) * framesPerNs   // unrounded
        var position: Int64
        var remapped = false
        var needsResync = false

        if hasLast && !forceRemap {
            let delta = Int64(bitPattern: stampHostNs &- lastStampNs)
            let k = Int64((Double(delta) / Double(chunkStampNs)).rounded())
            let residual = delta - k * chunkStampNs
            if k >= 1, k <= maxContiguousSkipChunks, abs(residual) <= residualToleranceNs {
                // Contiguous (k>1 = host skipped chunks: the hole stays zeroed
                // and renders as correctly-placed silence).
                position = lastPos + lastFrames + (k - 1) * chunkFrames
            } else {
                position = Int64(clockPos.rounded())
                remapped = true
            }
        } else {
            position = Int64(clockPos.rounded())
            remapped = true
        }

        if remapped {
            correctionEma = 0    // a remapped position IS the clock position
        } else {
            let corrRaw = Double(position) - clockPos
            if abs(corrRaw - correctionEma) > divergenceGuardFrames {
                // Stamps passed the k·20ms test but the timeline no longer
                // matches the clock (pathological stamps): break the epoch.
                position = Int64(clockPos.rounded())
                remapped = true
                needsResync = true
                correctionEma = 0
            } else {
                correctionEma += emaAlpha * (corrRaw - correctionEma)
            }
        }

        lastStampNs = stampHostNs
        lastPos = position
        lastFrames = Int64(frameCount)
        hasLast = true
        return Result(
            position: position,
            remapped: remapped,
            needsResync: needsResync,
            correctionFrames: correctionEma
        )
    }

    /// Forget the epoch (anchor change, reconnect).
    func reset() {
        hasLast = false
        correctionEma = 0
    }
}
