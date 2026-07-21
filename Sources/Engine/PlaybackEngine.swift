import Foundation
import AVFoundation
import Accelerate

/// Renders the party timeline on this machine's speakers, sample-locked to the
/// host's clock.
///
/// Chunks are placed on a `TimelineRingBuffer` by a `TimelinePlacer`
/// (contiguous while host stamps are continuous, clock-remapped on epoch
/// breaks); an `AVAudioSourceNode` pulls from the ring under a drift servo:
///
/// - each render cycle computes where the DAC "is" on the timeline
///   (`mHostTime` + output latency chain + user latency trim + the placer's
///   correction term) and compares it with the read position;
/// - |err| ≤ 1ms: deadband (integrator only);
/// - 1–24ms: slew via fractional-rate linear-interpolation resampling
///   (PI controller, ratio clamped to ±2000ppm — inaudible pitch shift);
/// - > 24ms or an external `hardResync()`: fade out, jump, fade in.
///
/// Underruns and lost chunks render as silence (never-written ring regions are
/// zero) and playback recovers at the correct instant automatically.
///
/// Lifecycle (`start`/`stop`/device-change restarts) is serialized on
/// `controlQueue` — AVAudioEngine is not thread-safe and callers arrive from
/// the main thread (host) and the net queue (client).
final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let clock: TimelineMapping
    private let state = RenderState()
    private let placer = TimelinePlacer()
    private let controlQueue = DispatchQueue(label: "africa.inpathgroup.cozyplay.playback.control")
    private var configChangeObserver: NSObjectProtocol?
    private let renderFormat = AVAudioFormat(
        standardFormatWithSampleRate: Double(EngineConstants.sampleRate),
        channels: AVAudioChannelCount(EngineConstants.channels)
    )!

    // Restart-retry state (controlQueue-confined).
    private var restartAttempts = 0
    private var retryWorkItem: DispatchWorkItem?
    private var issueActive = false

    // Cross-thread flags/counters owned here (rest live in RenderState).
    private let writerRemapFlagStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let engineRestartsStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let engineRestartFailuresStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    private(set) var isRunning = false

    /// Fired on the main queue with a user-facing message when playback dies
    /// and can't recover (nil = a previously reported issue resolved).
    var onPlaybackIssue: ((String?) -> Void)?

    var volumePercent: Int = 100 { didSet { applyVolume() } }
    var muted: Bool = false { didSet { applyVolume() } }

    /// Positive values make this speaker play *earlier* — nudge upward if this
    /// speaker's output chain is slower than Core Audio reports.
    var latencyTrimMs: Int = 0 {
        didSet { state.setLatencyTrimNs(Int64(max(-100, min(100, latencyTrimMs))) * 1_000_000) }
    }

    init(clock: TimelineMapping) {
        self.clock = clock
        writerRemapFlagStorage.initialize(to: 0)
        engineRestartsStorage.initialize(to: 0)
        engineRestartFailuresStorage.initialize(to: 0)
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        writerRemapFlagStorage.deallocate()
        engineRestartsStorage.deallocate()
        engineRestartFailuresStorage.deallocate()
    }

    // MARK: Lifecycle (serialized on controlQueue)

    func start() throws {
        try controlQueue.sync { try startLocked() }
    }

    func stop() {
        controlQueue.sync { stopLocked() }
    }

    private func startLocked() throws {
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
            guard let self else { return }
            self.controlQueue.async { self.restartEngine() }
        }

        engine.prepare()
        try engine.start()
        state.setLatencyCompensationNs(Self.outputLatencyNs(of: engine))
        isRunning = true
    }

    private func stopLocked() {
        guard isRunning else { return }
        retryWorkItem?.cancel()
        retryWorkItem = nil
        restartAttempts = 0
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
        placer.reset()
        isRunning = false
    }

    /// Output device changed (headphones plugged in, default device switched,
    /// the host's tap aggregate perturbing the device): restart the engine,
    /// re-measure the output latency chain, hard-resync. Retries with backoff
    /// and SURFACES persistent failure — a swallowed throw here is silent
    /// playback death.
    private func restartEngine() {
        guard isRunning else { return }
        retryWorkItem?.cancel()
        retryWorkItem = nil

        engine.stop()
        engine.prepare()
        do {
            try engine.start()
            state.setLatencyCompensationNs(Self.outputLatencyNs(of: engine))
            applyVolume()
            hardResync()
            restartAttempts = 0
            _ = rt_atomic_add(engineRestartsStorage, 1)
            if issueActive {
                issueActive = false
                notifyIssue(nil)
            }
        } catch {
            restartAttempts += 1
            if restartAttempts >= 5 {
                restartAttempts = 0    // future config changes retry fresh
                _ = rt_atomic_add(engineRestartFailuresStorage, 1)
                issueActive = true
                notifyIssue("Playback couldn't restart after an audio device change: \(error.localizedDescription)")
                return
            }
            let delay = 0.5 * pow(2.0, Double(restartAttempts - 1))   // 0.5, 1, 2, 4s
            let item = DispatchWorkItem { [weak self] in self?.restartEngine() }
            retryWorkItem = item
            controlQueue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func notifyIssue(_ message: String?) {
        DispatchQueue.main.async { [onPlaybackIssue] in onPlaybackIssue?(message) }
    }

    // MARK: Ingest (net queue)

    /// Map the chunk onto the local timeline and write it into the ring.
    /// Before the clock converges, chunks are dropped (playback hasn't anchored).
    func ingest(_ chunk: AudioChunk) {
        let playAtLocalNs = Int64(bitPattern: clock.localNs(fromHostNs: chunk.playAtHostNs))
        if !state.isAnchored {
            guard clock.isConverged else { return }
            state.anchor(atLocalNs: playAtLocalNs)
            placer.reset()
        }
        let forceRemap = rt_atomic_exchange(writerRemapFlagStorage, 0) != 0
        let result = placer.place(
            stampHostNs: chunk.playAtHostNs,
            mappedLocalNs: playAtLocalNs,
            anchorNs: state.anchorNsValue,
            frameCount: Int(chunk.frameCount),
            forceRemap: forceRemap
        )
        state.setCorrectionMicroFrames(Int64(result.correctionFrames * 1e6))
        if result.needsResync {
            state.requestResync()
        }
        state.ring.write(samplesS16: chunk.samples, at: result.position)
    }

    /// Jump the reader straight to the timeline position the clock now implies
    /// (clock step, device change) — and break the writer's placement epoch so
    /// the next chunk remaps through the stepped clock.
    func hardResync() {
        rt_atomic_store(writerRemapFlagStorage, 1)
        state.requestResync()
    }

    // MARK: Diagnostics

    struct Diagnostics {
        var bufferedMs: Int
        var servoErrorMs: Double
        /// Max |sample| rendered since the previous snapshot (0…1). The
        /// host-silence discriminator: >0 while inaudible ⇒ audio is killed
        /// downstream of this process; 0 with healthy writes ⇒ ring/anchor
        /// problem; no lastRender updates ⇒ engine dead.
        var renderPeak: Double
        var msSinceLastRender: Int      // -1 if the render callback never ran
        var underrunCycles: Int
        var invalidTimestampCycles: Int
        var jumpCount: Int
        var lateDrops: Int
        var earlyDrops: Int
        var writesOK: Int
        var engineRestarts: Int
        var engineRestartFailures: Int
    }

    /// Callable from any queue. Resets the render-peak high-water mark.
    func snapshotDiagnostics() -> Diagnostics {
        let lastRender = state.lastRenderNs
        return Diagnostics(
            bufferedMs: Int(state.ring.bufferedFrames * 1000 / Int64(EngineConstants.sampleRate)),
            servoErrorMs: state.servoErrorMs,
            renderPeak: state.takeRenderPeak(),
            msSinceLastRender: lastRender == 0 ? -1 : Int((HostClock.nowNs() - min(lastRender, HostClock.nowNs())) / 1_000_000),
            underrunCycles: Int(state.underrunCycles),
            invalidTimestampCycles: Int(state.invalidTimestampCycles),
            jumpCount: Int(state.jumpCount),
            lateDrops: Int(state.ring.lateDrops),
            earlyDrops: Int(state.ring.earlyDrops),
            writesOK: Int(state.ring.writesOK),
            engineRestarts: Int(rt_atomic_load(engineRestartsStorage)),
            engineRestartFailures: Int(rt_atomic_load(engineRestartFailuresStorage))
        )
    }

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
    private let correctionMicroFramesStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let resyncFlagStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let servoErrUsStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let invalidTimestampCyclesStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let underrunCyclesStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let jumpCountStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let renderPeakMicroStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let lastRenderNsStorage = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    // Render-thread-private servo state.
    private var readFrac: Double = 0
    private var integrator: Double = 0
    private var smoothedErr: Double = 0
    private var lastRatio: Double = 1.0
    private var lastZeroed: Int64 = 0
    private var renderAnchored = false
    private var fadeOutThenJump = false

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
        correctionMicroFramesStorage.initialize(to: 0)
        resyncFlagStorage.initialize(to: 0)
        servoErrUsStorage.initialize(to: 0)
        invalidTimestampCyclesStorage.initialize(to: 0)
        underrunCyclesStorage.initialize(to: 0)
        jumpCountStorage.initialize(to: 0)
        renderPeakMicroStorage.initialize(to: 0)
        lastRenderNsStorage.initialize(to: 0)
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
        correctionMicroFramesStorage.deallocate()
        resyncFlagStorage.deallocate()
        servoErrUsStorage.deallocate()
        invalidTimestampCyclesStorage.deallocate()
        underrunCyclesStorage.deallocate()
        jumpCountStorage.deallocate()
        renderPeakMicroStorage.deallocate()
        lastRenderNsStorage.deallocate()
    }

    // MARK: Writer/control side

    var isAnchored: Bool { rt_atomic_load(anchorNsStorage) != Self.anchorSentinel }
    var anchorNsValue: Int64 { rt_atomic_load(anchorNsStorage) }

    func anchor(atLocalNs ns: Int64) {
        rt_atomic_store(anchorNsStorage, ns)
    }

    func setLatencyCompensationNs(_ ns: Int64) { rt_atomic_store(latencyCompNsStorage, ns) }
    func setLatencyTrimNs(_ ns: Int64) { rt_atomic_store(latencyTrimNsStorage, ns) }
    func setCorrectionMicroFrames(_ microFrames: Int64) { rt_atomic_store(correctionMicroFramesStorage, microFrames) }
    func requestResync() { rt_atomic_store(resyncFlagStorage, 1) }

    var servoErrorMs: Double { Double(rt_atomic_load(servoErrUsStorage)) / 1_000 }
    var invalidTimestampCycles: Int64 { rt_atomic_load(invalidTimestampCyclesStorage) }
    var underrunCycles: Int64 { rt_atomic_load(underrunCyclesStorage) }
    var jumpCount: Int64 { rt_atomic_load(jumpCountStorage) }
    var lastRenderNs: UInt64 { UInt64(bitPattern: rt_atomic_load(lastRenderNsStorage)) }

    /// Returns and resets the render-peak high-water mark (0…1).
    func takeRenderPeak() -> Double {
        Double(rt_atomic_exchange(renderPeakMicroStorage, 0)) / 1e6
    }

    /// Full reset (engine stopped): drop the anchor and silence the ring.
    func resetTimeline() {
        rt_atomic_store(anchorNsStorage, Self.anchorSentinel)
        rt_atomic_store(correctionMicroFramesStorage, 0)
        ring.reset()
        readFrac = 0
        integrator = 0
        smoothedErr = 0
        lastRatio = 1.0
        lastZeroed = 0
        renderAnchored = false
        fadeOutThenJump = false
    }

    // MARK: Render thread

    func render(
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: Int,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) {
        rt_atomic_store(lastRenderNsStorage, Int64(bitPattern: HostClock.nowNs()))

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
            _ = rt_atomic_add(invalidTimestampCyclesStorage, 1)
            // Never dead-reckon before the first anchored render: readFrac
            // would advance from 0, race ahead of the writer, and every chunk
            // would late-drop forever (silent death).
            guard renderAnchored else {
                silence(frameCount)
                return
            }
            readAdvancing(frameCount: frameCount, ratio: lastRatio, fade: .none)
            return
        }

        let dacLocalNs = Int64(HostClock.ns(fromHostTicks: timestamp.pointee.mHostTime))
            + rt_atomic_load(latencyCompNsStorage)
            + rt_atomic_load(latencyTrimNsStorage)
        let desired = Double(dacLocalNs - anchor) * framesPerNs
            + Double(rt_atomic_load(correctionMicroFramesStorage)) / 1e6

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

        // Underrun: we're consuming real timeline (past position 0) but the
        // writer hasn't delivered this far yet.
        if base >= 0 && ring.writeHead - base < Int64(frameCount) {
            _ = rt_atomic_add(underrunCyclesStorage, 1)
        }

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

        updateRenderPeak(frameCount: frameCount)

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
        _ = rt_atomic_add(jumpCountStorage, 1)
    }

    private func applyRamp(from start: Float, frameCount: Int) {
        var rampStart = start
        var rampStep = (start == 0 ? 1 : -1) / Float(frameCount)
        for ch in 0..<channelCount {
            guard let dst = outputDsts[ch] else { continue }
            vDSP_vrampmul(dst, 1, &rampStart, &rampStep, dst, 1, vDSP_Length(frameCount))
        }
    }

    private func updateRenderPeak(frameCount: Int) {
        var cyclePeak: Float = 0
        for ch in 0..<channelCount {
            guard let dst = outputDsts[ch] else { continue }
            var channelPeak: Float = 0
            vDSP_maxmgv(dst, 1, &channelPeak, vDSP_Length(frameCount))
            cyclePeak = max(cyclePeak, channelPeak)
        }
        let micro = Int64(min(cyclePeak, 1) * 1e6)
        if micro > rt_atomic_load(renderPeakMicroStorage) {
            rt_atomic_store(renderPeakMicroStorage, micro)
        }
    }

    private func silence(_ frameCount: Int) {
        for ch in 0..<channelCount {
            guard let dst = outputDsts[ch] else { continue }
            vDSP_vclr(dst, 1, vDSP_Length(frameCount))
        }
    }
}
