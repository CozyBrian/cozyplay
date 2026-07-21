import Foundation
import AVFoundation
import Combine

/// Drives the "Host a party" role: captures system audio via the Core Audio process
/// tap and feeds the native sync engine, which streams timestamped chunks to every
/// joined laptop (and this Mac's own speakers) and owns the speaker roster.
@MainActor
final class HostController: ObservableObject {
    @Published var speakers: [Speaker] = []
    @Published var statusText = "Starting party…"
    @Published var errorText: String?
    @Published var level: Float = 0
    @Published var isCapturing = false
    @Published var bufferMs = AppSettings.defaultBufferMs
    @Published var diagnostics: AudioServer.HostDiagnostics?

    let partyName: String

    private let tap = SystemAudioTap()
    private let meter = AudioMeter()
    private var converter: PCMConverter?
    private var engine: AudioServer?
    private let localHostID = HostIdentity.stableID()

    init(partyName: String) {
        self.partyName = partyName
    }

    func start() {
        meter.onLevel = { [weak self] in self?.level = $0 }
        // ORDER IS LOAD-BEARING: startEngine() starts local playback, which
        // registers this process with coreaudiod — required for the tap's
        // self-exclusion PID translation in startCapture(). Reversing this can
        // make the tap capture (and mute) our own output.
        startEngine()
        startCapture()
    }

    private func startEngine() {
        let engine = AudioServer(
            partyName: partyName,
            localName: deviceName(),
            localHostID: localHostID,
            bufferMs: bufferMs
        )
        engine.onSpeakers = { [weak self] speakers in
            guard let self else { return }
            self.speakers = speakers.map { speaker in
                var s = speaker
                s.isThisMac = (speaker.id == self.localHostID)
                return s
            }
        }
        engine.onReady = { [weak self] _ in
            guard let self else { return }
            self.statusText = "Hosting “\(self.partyName)” — waiting for laptops to join"
        }
        engine.onError = { [weak self] message in
            self?.errorText = message
            self?.statusText = "Party engine not fully started"
        }
        engine.onLocalPlaybackIssue = { [weak self] message in
            self?.errorText = message   // nil clears a recovered issue
        }
        engine.onDiagnostics = { [weak self] snapshot in
            self?.diagnostics = snapshot
        }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusText = "Party engine not fully started"
        }
    }

    private func startCapture() {
        do {
            try tap.start(keepSourceAudible: AppSettings.keepSourceAudible) { [weak self] buffer, hostTimeNs in
                guard let self else { return }
                self.meter.process(buffer)
                if self.converter == nil, let fmt = self.tap.format {
                    self.converter = PCMConverter(inputFormat: fmt)
                }
                if let data = self.converter?.convertToData(buffer) {
                    self.engine?.ingest(data, firstFrameHostNs: hostTimeNs)
                }
            }
            isCapturing = true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Speaker controls (proxied to the engine's roster authority)

    func setVolume(_ speaker: Speaker, percent: Int) {
        engine?.setVolume(clientID: speaker.id, percent: percent, muted: speaker.isMuted)
    }

    func setMuted(_ speaker: Speaker, muted: Bool) {
        engine?.setVolume(clientID: speaker.id, percent: speaker.volumePercent, muted: muted)
    }

    func rename(_ speaker: Speaker, to name: String) {
        engine?.setName(clientID: speaker.id, name: name)
    }

    func setLatency(_ speaker: Speaker, ms: Int) {
        engine?.setLatency(clientID: speaker.id, latencyMs: ms)
    }

    /// Live party-wide delay change; also becomes the default for new parties.
    func setBuffer(ms: Int) {
        let clamped = max(EngineConstants.minBufferMs, min(EngineConstants.maxBufferMs, ms))
        bufferMs = clamped
        AppSettings.defaultBufferMs = clamped
        engine?.setBuffer(ms: clamped)
    }

    func stop() {
        tap.stop()
        engine?.stop()
        engine = nil
    }

    private func deviceName() -> String { AppSettings.deviceName() }
}
