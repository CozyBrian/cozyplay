import Foundation
import AVFoundation

/// The sync engine's format and timing contract, shared by host capture,
/// the wire protocol, and client playback.
enum EngineConstants {
    // Wire/processing format: interleaved S16LE, 48kHz stereo.
    static let sampleRate = 48_000
    static let bitDepth = 16
    static let channels = 2

    /// Frames per network chunk: 20ms @ 48kHz.
    static let chunkFrames = 960
    static var chunkBytes: Int { chunkFrames * bytesPerFrame }
    static var bytesPerFrame: Int { channels * (bitDepth / 8) }

    /// End-to-end playback delay from capture to every speaker's DAC.
    static let defaultBufferMs = 150
    static let minBufferMs = 60
    static let maxBufferMs = 500

    /// The wire format as an `AVAudioFormat` (S16LE interleaved @ 48k stereo).
    static var wireFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        )!
    }
}
