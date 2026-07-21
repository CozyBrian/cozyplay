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
    private let localHostID = HostIdentity.stableID()
    // TODO(M-2): AudioServer — NWListener + Bonjour service, chunk fan-out,
    // local playback injection, speaker roster authority.

    init(partyName: String) {
        self.partyName = partyName
    }

    func start() {
        meter.onLevel = { [weak self] in self?.level = $0 }
        startEngine()
        startCapture()
    }

    private func startEngine() {
        // Native engine lands in M-2; until then hosting is capture + local roster only.
        speakers = [Speaker(
            id: localHostID,
            name: "\(deviceName()) (host)",
            host: deviceName(),
            volumePercent: 100,
            isMuted: false,
            latencyMs: 0,
            isConnected: true,
            isThisMac: true
        )]
        statusText = "Hosting “\(partyName)” — native engine not streaming yet"
    }

    private func startCapture() {
        do {
            try tap.start { [weak self] buffer in
                guard let self else { return }
                self.meter.process(buffer)
                if self.converter == nil, let fmt = self.tap.format {
                    self.converter = PCMConverter(inputFormat: fmt)
                }
                // TODO(M-2): engine.ingest(converter output + capture hostTime)
            }
            isCapturing = true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Speaker controls (proxied to the engine's roster authority)

    func setVolume(_ speaker: Speaker, percent: Int) {
        // TODO(M-4): engine.setVolume(clientID:percent:muted:)
        update(speaker.id) { $0.volumePercent = percent }
    }

    func setMuted(_ speaker: Speaker, muted: Bool) {
        // TODO(M-4): engine.setVolume(clientID:percent:muted:)
        update(speaker.id) { $0.isMuted = muted }
    }

    func rename(_ speaker: Speaker, to name: String) {
        // TODO(M-4): engine.setName(clientID:name:)
        update(speaker.id) { $0.name = name }
    }

    func setLatency(_ speaker: Speaker, ms: Int) {
        // TODO(M-4): engine.setLatency(clientID:latencyMs:)
        update(speaker.id) { $0.latencyMs = ms }
    }

    func stop() {
        tap.stop()
    }

    private func update(_ id: String, _ mutate: (inout Speaker) -> Void) {
        guard let i = speakers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&speakers[i])
    }

    private func deviceName() -> String { Host.current().localizedName ?? "MacBook" }
}
