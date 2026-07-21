import Foundation
import AVFoundation

/// Renders the party stream on this machine's speakers.
///
/// `AVAudioSourceNode` (pull model) reads deinterleaved Float32 out of a
/// `TimelineRingBuffer`; regions that never arrived render as silence, so
/// underruns self-heal without a state machine in the render path.
///
/// M-2 operates play-on-arrival: chunks are written at sequential ring
/// positions with a prefill lead over the reader (no cross-machine sync yet).
/// M-3 replaces position assignment with the clock-mapped timeline + drift
/// servo.
final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring = TimelineRingBuffer()
    private let renderFormat = AVAudioFormat(
        standardFormatWithSampleRate: Double(EngineConstants.sampleRate),
        channels: AVAudioChannelCount(EngineConstants.channels)
    )!

    /// Preallocated per-render destination pointers (no allocation on the RT thread).
    private let renderDestinations = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
        .allocate(capacity: EngineConstants.channels)

    // Play-on-arrival state (writer side, net queue).
    private var nextWritePos: Int64 = 0
    private let prefillFrames = Int64(EngineConstants.sampleRate / 10)   // 100ms lead
    private let minLeadFrames = Int64(EngineConstants.chunkFrames)

    private(set) var isRunning = false

    var volumePercent: Int = 100 { didSet { applyVolume() } }
    var muted: Bool = false { didSet { applyVolume() } }

    deinit {
        renderDestinations.deallocate()
    }

    func start() throws {
        guard !isRunning else { return }
        ring.reset()
        nextWritePos = 0

        let ring = self.ring
        let destinations = self.renderDestinations
        let channelCount = EngineConstants.channels
        let node = AVAudioSourceNode(format: renderFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for ch in 0..<channelCount {
                destinations[ch] = ch < buffers.count
                    ? buffers[ch].mData?.assumingMemoryBound(to: Float.self)
                    : nil
            }
            let position = ring.readPosition
            ring.read(
                into: UnsafeMutableBufferPointer(start: destinations, count: channelCount),
                from: position,
                frames: Int(frameCount)
            )
            ring.readPosition = position + Int64(frameCount)
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
        sourceNode = node
        applyVolume()
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        isRunning = false
    }

    /// Diagnostics: how much real audio is buffered ahead of the reader.
    var bufferedMs: Int {
        Int(ring.bufferedFrames * 1000 / Int64(EngineConstants.sampleRate))
    }

    // MARK: Ingest (net queue)

    /// Play-on-arrival: write at the next sequential position, keeping a
    /// prefill lead over the reader; if the buffer ran dry (network stall),
    /// jump forward and rebuild the lead.
    func ingestPlayOnArrival(_ chunk: AudioChunk) {
        let readPos = ring.readPosition
        if nextWritePos < readPos + minLeadFrames {
            nextWritePos = readPos + prefillFrames
        }
        ring.write(samplesS16: chunk.samples, at: nextWritePos)
        nextWritePos += Int64(chunk.frameCount)
    }

    // MARK: Internals

    private func applyVolume() {
        engine.mainMixerNode.outputVolume = muted ? 0 : Float(volumePercent) / 100
    }
}
