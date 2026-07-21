import Foundation
import AVFoundation
import Accelerate

/// Renders the party timeline on this machine's speakers, sample-locked to the
/// host's clock.
///
/// Chunks are written into a `TimelineRingBuffer` at the position their
/// play-at timestamp maps to (via the injected `TimelineMapping`); an
/// `AVAudioSourceNode` pulls from the ring under a drift servo:
///
/// - each render cycle computes where the DAC "is" on the timeline
///   (`mHostTime` + output latency chain + user latency trim) and compares it
///   with the read position;
/// - |err| ≤ 1ms: deadband (integrator only);
/// - 1–24ms: slew via fractional-rate linear-interpolation resampling
///   (PI controller, ratio clamped to ±2000ppm — inaudible pitch shift);
/// - > 24ms or an external `hardResync()`: fade out, jump, fade in.
///
/// Underruns and lost chunks render as silence (never-written ring regions are
/// zero) and playback recovers at the correct instant automatically.
final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let clock: TimelineMapping
    private let state = RenderState()
    private let controlQueue = DispatchQueue(label: "africa.inpathgroup.cozyplay.playback.control")
    private var configChangeObserver: NSObjectProtocol?
    private let renderFormat = AVAudioFormat(
        standardFormatWithSampleRate: Double(EngineConstants.sampleRate),
        channels: AVAudioChannelCount(EngineConstants.channels)
    )!

    private(set) var isRunning = false

    var volumePercent: Int = 100 { didSet { applyVolume() } }
    var muted: Bool = false { didSet { applyVolume() } }

    /// Positive values make this speaker play *earlier* — nudge upward if this
    /// speaker's output chain is slower than Core Audio reports.
    var latencyTrimMs: Int = 0 {
        didSet { state.setLatencyTrimNs(Int64(max(-100, min(100, latencyTrimMs))) * 1_000_000) }
    }

    init(clock: TimelineMapping) {
        self.clock = clock
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Lifecycle

    func start() throws {
        guard !isRunning else { return }

        let state = self.state
        let node = AVAudioSourceNode(format: renderFormat) { _, timestamp, frameCount, audioBufferList -> OSStatus in
            state.render(timestamp: timestamp, frameCount: Int(frameCount), audioBufferList: audioBufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
        sourceNode = node
        applyVolume()

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }

        engine.prepare()
        try engine.start()
        state.setLatencyCompensationNs(Self.outputLatencyNs(of: engine))
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        state.resetTimeline()
        isRunning = false
    }

    /// Output device changed (headphones plugged in, default device switched):
    /// restart the engine, re-measure the output latency chain, hard-resync.
    private func handleConfigurationChange() {
        controlQueue.async { [self] in
            guard isRunning else { return }
            engine.stop()
            engine.prepare()
            do {
                try engine.start()
                state.setLatencyCompensationNs(Self.outputLatencyNs(of: engine))
                applyVolume()
                hardResync()
            } catch {
                // Output is gone entirely; the ring keeps absorbing chunks and a
                // later config change (device back) will restart playback.
            }
        }
    }

    // MARK: Ingest (net queue)

    /// Map the chunk's play-at host time onto the local timeline and write it.
    /// Before the clock converges, chunks are dropped (playback hasn't anchored).
    func ingest(_ chunk: AudioChunk) {
        let playAtLocalNs = Int64(bitPattern: clock.localNs(fromHostNs: chunk.playAtHostNs))
        if !state.isAnchored {
            guard clock.isConverged else { return }
            state.anchor(atLocalNs: playAtLocalNs)
        }
        let position = state.timelinePosition(forLocalNs: playAtLocalNs)
        state.ring.write(samplesS16: chunk.samples, at: position)
    }

    /// Jump the reader straight to the timeline position the clock now implies
    /// (clock step, device change, buffer change).
    func hardResync() {
        state.requestResync()
    }

    // MARK: Diagnostics

    var bufferedMs: Int {
        Int(state.ring.bufferedFrames * 1000 / Int64(EngineConstants.sampleRate))
    }

    /// Last smoothed servo error in milliseconds (reader late = positive).
    var servoErrorMs: Double { state.servoErrorMs }

    // MARK: Internals

    private func applyVolume() {
        engine.mainMixerNode.outputVolume = muted ? 0 : Float(volumePercent) / 100
    }

    /// Sum of the output device/stream/safety latencies, in ns at the device rate.
    /// (`AVAudioIONode.presentationLatency` only covers the device term.)
    private static func outputLatencyNs(of engine: AVAudioEngine) -> Int64 {
        guard let unit = engine.outputNode.audioUnit else { return 0 }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, &size
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return 0 }

        func property(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> UInt32 {
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let ok = AudioObjectGetPropertyData(object, &address, 0, nil, &valueSize, &value)
            return ok == noErr ? value : 0
        }

        var frames = UInt64(property(kAudioDevicePropertyLatency, of: deviceID))
            + UInt64(property(kAudioDevicePropertySafetyOffset, of: deviceID))

        // First output stream's own latency.
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamsSize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, &streamsSize, &streams) == noErr,
               let first = streams.first {
                frames += UInt64(property(kAudioStreamPropertyLatency, of: first))
            }
        }

        var rate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &rate)
        guard rate > 0 else { return 0 }
        return Int64(Double(frames) * 1e9 / rate)
    }
}

// MARK: - Render state

/// Everything the render block touches. The source-node closure captures only
/// this object (never the engine), so there is no retain cycle through the
/// audio graph, and the render path stays free of locks and allocation:
/// cross-thread values go through the C-shim atomics, the rest is
/// render-thread-private.
private final class RenderState {
    let ring = TimelineRingBuffer()

    private static let anchorSentinel = Int64.min
    private let framesPerNs = Double(EngineConstants.sampleRate) / 1e9

    // Cross-thread (C-shim atomics).
    private let anchorNsStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let latencyCompNsStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let latencyTrimNsStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let resyncFlagStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let servoErrUsStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    // Render-thread-private servo state.
    private var readFrac: Double = 0
    private var integrator: Double = 0
    private var smoothedErr: Double = 0
    private var lastRatio: Double = 1.0
    private var lastZeroed: Int64 = 0
    private var renderAnchored = false
    private var fadeOutThenJump = false
    private var fadeInPending = false

    // Servo tuning.
    private let deadbandFrames = 48.0          // 1ms
    private let jumpThresholdFrames = 1_152.0  // 24ms
    private let maxRatioOffset = 0.002         // ±2000ppm
    private let kp = 0.002 / 240.0             // saturates at ~5ms error
    private let ki = 0.0000002
    private let integratorClamp = 0.0005       // ±500ppm steady-state drift

    // Preallocated render scratch.
    private let scratchCapacity = 8_192
    private var scratch: [UnsafeMutablePointer<Float>] = []
    private let indexRamp: UnsafeMutablePointer<Float>
    private let scratchDsts: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let outputDsts: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let channelCount = EngineConstants.channels

    init() {
        anchorNsStorage.initialize(to: Self.anchorSentinel)
        latencyCompNsStorage.initialize(to: 0)
        latencyTrimNsStorage.initialize(to: 0)
        resyncFlagStorage.initialize(to: 0)
        servoErrUsStorage.initialize(to: 0)
        for _ in 0..<channelCount {
            let s = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
            s.initialize(repeating: 0, count: scratchCapacity)
            scratch.append(s)
        }
        indexRamp = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        indexRamp.initialize(repeating: 0, count: scratchCapacity)
        scratchDsts = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channelCount)
        outputDsts = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channelCount)
        for ch in 0..<channelCount {
            scratchDsts[ch] = scratch[ch]
            outputDsts[ch] = nil
        }
    }

    deinit {
        scratch.forEach { $0.deallocate() }
        indexRamp.deallocate()
        scratchDsts.deallocate()
        outputDsts.deallocate()
        anchorNsStorage.deallocate()
        latencyCompNsStorage.deallocate()
        latencyTrimNsStorage.deallocate()
        resyncFlagStorage.deallocate()
        servoErrUsStorage.deallocate()
    }

    // MARK: Writer/control side

    var isAnchored: Bool { rt_atomic_load(anchorNsStorage) != Self.anchorSentinel }

    func anchor(atLocalNs ns: Int64) {
        rt_atomic_store(anchorNsStorage, ns)
    }

    func timelinePosition(forLocalNs ns: Int64) -> Int64 {
        Int64((Double(ns - rt_atomic_load(anchorNsStorage)) * framesPerNs).rounded())
    }

    func setLatencyCompensationNs(_ ns: Int64) { rt_atomic_store(latencyCompNsStorage, ns) }
    func setLatencyTrimNs(_ ns: Int64) { rt_atomic_store(latencyTrimNsStorage, ns) }
    func requestResync() { rt_atomic_store(resyncFlagStorage, 1) }
    var servoErrorMs: Double { Double(rt_atomic_load(servoErrUsStorage)) / 1_000 }

    /// Full reset (engine stopped): drop the anchor and silence the ring.
    func resetTimeline() {
        rt_atomic_store(anchorNsStorage, Self.anchorSentinel)
        ring.reset()
        readFrac = 0
        integrator = 0
        smoothedErr = 0
        lastRatio = 1.0
        lastZeroed = 0
        renderAnchored = false
        fadeOutThenJump = false
        fadeInPending = false
    }

    // MARK: Render thread

    func render(
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: Int,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for ch in 0..<channelCount {
            outputDsts[ch] = ch < buffers.count
                ? buffers[ch].mData?.assumingMemoryBound(to: Float.self)
                : nil
        }

        let anchor = rt_atomic_load(anchorNsStorage)
        guard anchor != Self.anchorSentinel, frameCount <= scratchCapacity - 8 else {
            silence(frameCount)
            return
        }

        guard timestamp.pointee.mFlags.contains(.hostTimeValid) else {
            // No usable timestamp this cycle: dead-reckon at the last ratio.
            readAdvancing(frameCount: frameCount, ratio: lastRatio, fade: .none)
            return
        }

        let dacLocalNs = Int64(HostClock.ns(fromHostTicks: timestamp.pointee.mHostTime))
            + rt_atomic_load(latencyCompNsStorage)
            + rt_atomic_load(latencyTrimNsStorage)
        let desired = Double(dacLocalNs - anchor) * framesPerNs

        if !renderAnchored {
            readFrac = desired
            lastZeroed = Int64(desired.rounded(.down))
            renderAnchored = true
        }

        let resyncRequested = rt_atomic_load(resyncFlagStorage) != 0
        let err = desired - readFrac
        smoothedErr += 0.1 * (err - smoothedErr)
        rt_atomic_store(servoErrUsStorage, Int64((smoothedErr / framesPerNs / 1_000).rounded()))

        if resyncRequested || abs(err) > jumpThresholdFrames {
            if !resyncRequested && !fadeOutThenJump {
                // Phase 1: fade this cycle out at the old position, jump next cycle.
                fadeOutThenJump = true
                readAdvancing(frameCount: frameCount, ratio: 1.0, fade: .out)
                return
            }
            rt_atomic_store(resyncFlagStorage, 0)
            fadeOutThenJump = false
            jump(to: desired)
            readAdvancing(frameCount: frameCount, ratio: 1.0, fade: .in)
            return
        }
        fadeOutThenJump = false

        integrator = max(-integratorClamp, min(integratorClamp, integrator + ki * smoothedErr))
        let proportional = abs(smoothedErr) > deadbandFrames ? kp * smoothedErr : 0
        let ratio = 1.0 + max(-maxRatioOffset, min(maxRatioOffset, proportional + integrator))
        readAdvancing(frameCount: frameCount, ratio: ratio, fade: .none)
    }

    private enum Fade { case none, `in`, out }

    /// Read `frameCount` output frames from `readFrac` at `ratio` input frames
    /// per output frame (linear interpolation), then advance and zero behind.
    private func readAdvancing(frameCount: Int, ratio: Double, fade: Fade) {
        lastRatio = ratio
        let base = Int64(readFrac.rounded(.down))
        let frac0 = Float(readFrac - Double(base))
        let span = min(scratchCapacity, Int((Double(frac0) + Double(frameCount) * ratio).rounded(.up)) + 2)

        ring.read(
            into: UnsafeMutableBufferPointer(start: scratchDsts, count: channelCount),
            from: base,
            frames: span
        )

        var rampStart = frac0
        var rampStep = Float(ratio)
        vDSP_vramp(&rampStart, &rampStep, indexRamp, 1, vDSP_Length(frameCount))
        for ch in 0..<channelCount {
            guard let dst = outputDsts[ch] else { continue }
            vDSP_vlint(scratch[ch], indexRamp, 1, dst, 1, vDSP_Length(frameCount), vDSP_Length(span))
        }

        switch fade {
        case .none:
            break
        case .in:
            applyRamp(from: 0, frameCount: frameCount)
        case .out:
            applyRamp(from: 1, frameCount: frameCount)
        }

        readFrac += Double(frameCount) * ratio
        let newFloor = Int64(readFrac.rounded(.down))
        ring.zero(from: lastZeroed, to: newFloor - 2)
        lastZeroed = max(lastZeroed, newFloor - 2)
        ring.readPosition = newFloor
    }

    private func jump(to desired: Double) {
        let target = Int64(desired.rounded(.down))
        if target > lastZeroed {
            // Silence the skipped region so it can't replay as stale audio later.
            ring.zero(from: lastZeroed, to: target)
        }
        readFrac = desired
        lastZeroed = target
        smoothedErr = 0
    }

    private func applyRamp(from start: Float, frameCount: Int) {
        var rampStart = start
        var rampStep = (start == 0 ? 1 : -1) / Float(frameCount)
        for ch in 0..<channelCount {
            guard let dst = outputDsts[ch] else { continue }
            vDSP_vrampmul(dst, 1, &rampStart, &rampStep, dst, 1, vDSP_Length(frameCount))
        }
    }

    private func silence(_ frameCount: Int) {
        for ch in 0..<channelCount {
            guard let dst = outputDsts[ch] else { continue }
            vDSP_vclr(dst, 1, vDSP_Length(frameCount))
        }
    }
}
