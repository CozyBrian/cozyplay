import Foundation
import AVFoundation

/// Converts captured audio (Float32, at the tapped device's mix format — rate,
/// channel count and interleaving all vary) into the interleaved **Int16 @ 48kHz
/// stereo** that snapserver's pipe source requires. Snapcast's pipe accepts integer
/// PCM only, so this Float32 → S16LE step is mandatory.
final class PCMConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    /// - Parameter inputFormat: the tap's actual format, read from `kAudioTapPropertyFormat`.
    init?(inputFormat: AVAudioFormat) {
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(SnapcastServer.sampleRate),
            channels: AVAudioChannelCount(SnapcastServer.channels),
            interleaved: true
        ), let conv = AVAudioConverter(from: inputFormat, to: outFormat) else {
            return nil
        }
        outputFormat = outFormat
        converter = conv
    }

    /// Convert one input buffer and return interleaved S16LE bytes, or nil on failure.
    func convertToData(_ input: AVAudioPCMBuffer) -> Data? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, error == nil,
              let channelData = output.int16ChannelData, output.frameLength > 0 else {
            return nil
        }

        let byteCount = Int(output.frameLength) * Int(outputFormat.channelCount) * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }
}
