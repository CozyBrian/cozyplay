import Foundation
import AVFoundation

/// Computes a smoothed 0...1 level (RMS) from Float32 buffers for the now-playing
/// meter. Also serves as the sanity check that the tap is delivering real audio and
/// not the all-zero buffers a misconfigured aggregate device silently produces.
final class AudioMeter {
    /// Delivered on the main queue.
    var onLevel: ((Float) -> Void)?

    private var smoothed: Float = 0
    private let attack: Float = 0.5
    private let release: Float = 0.15

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var sumSquares: Float = 0
        for ch in 0..<channelCount {
            let samples = channels[ch]
            for i in 0..<frames { sumSquares += samples[i] * samples[i] }
        }
        let rms = sqrt(sumSquares / Float(frames * max(channelCount, 1)))
        let level = min(1, rms * 3) // light gain so quiet material still moves the meter

        let coeff = level > smoothed ? attack : release
        smoothed += (level - smoothed) * coeff
        let out = smoothed
        DispatchQueue.main.async { self.onLevel?(out) }
    }

    /// True once any non-zero audio has been observed.
    private(set) var hasSignal = false
}
