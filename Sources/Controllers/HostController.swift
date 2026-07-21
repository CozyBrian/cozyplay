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
        startEngine()
        startCapture()
    }

    private func startEngine() {
        let engine = AudioServer(
            partyName: partyName,
            localName: deviceName(),
            localHostID: localHostID
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
            try tap.start { [weak self] buffer, hostTimeNs in
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

    func stop() {
        tap.stop()
        engine?.stop()
        engine = nil
    }

    private func deviceName() -> String { Host.current().localizedName ?? "MacBook" }
}
