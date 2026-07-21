import Foundation
import AVFoundation
import Combine

/// Drives the "Host a party" role: captures system audio, feeds snapserver through a
/// FIFO, joins the master's own speakers via a local snapclient, advertises over
/// Bonjour, and mirrors the connected speakers from snapserver's JSON-RPC.
@MainActor
final class HostController: ObservableObject {
    @Published var speakers: [Speaker] = []
    @Published var statusText = "Starting party…"
    @Published var errorText: String?
    @Published var level: Float = 0
    @Published var isCapturing = false

    let partyName: String
    private let fifoPath = NSTemporaryDirectory() + "cozyplay.fifo"

    private let tap = SystemAudioTap()
    private let meter = AudioMeter()
    private var converter: PCMConverter?
    private var pipe: PipeWriter?
    private var server: SnapcastServer?
    private var localClient: SnapcastClient?
    private var advertiser: BonjourAdvertiser?
    private var rpc: SnapcastRPC?
    private let localHostID = SnapcastClient.stableHostID()

    init(partyName: String) {
        self.partyName = partyName
    }

    func start() {
        meter.onLevel = { [weak self] in self?.level = $0 }
        startEngine()
        startCapture()
        startControl()
    }

    private func startEngine() {
        do {
            let pipe = PipeWriter(path: fifoPath)
            try pipe.ensureFIFO()
            self.pipe = pipe

            let server = SnapcastServer(fifoPath: fifoPath)
            try server.start()
            self.server = server
            pipe.openForWriting()

            let localClient = SnapcastClient(host: "127.0.0.1", hostID: localHostID, displayName: "\(deviceName()) (host)")
            try localClient.start()
            self.localClient = localClient

            let advertiser = BonjourAdvertiser(partyName: partyName)
            advertiser.start()
            self.advertiser = advertiser

            statusText = "Hosting “\(partyName)” — waiting for laptops to join"
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusText = "Party engine not fully started"
        }
    }

    private func startCapture() {
        do {
            try tap.start { [weak self] buffer in
                guard let self else { return }
                self.meter.process(buffer)
                if self.converter == nil, let fmt = self.tap.format {
                    self.converter = PCMConverter(inputFormat: fmt)
                }
                if let data = self.converter?.convertToData(buffer) {
                    self.pipe?.write(data)
                }
            }
            isCapturing = true
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func startControl() {
        let rpc = SnapcastRPC(host: "127.0.0.1")
        rpc.onSpeakers = { [weak self] speakers in
            guard let self else { return }
            self.speakers = speakers.map { speaker in
                var s = speaker
                s.isThisMac = (speaker.id == self.localHostID)
                return s
            }
        }
        rpc.start()
        self.rpc = rpc
    }

    // MARK: Speaker controls (proxied to snapserver)

    func setVolume(_ speaker: Speaker, percent: Int) {
        rpc?.setVolume(clientID: speaker.id, percent: percent, muted: speaker.isMuted)
    }

    func setMuted(_ speaker: Speaker, muted: Bool) {
        rpc?.setVolume(clientID: speaker.id, percent: speaker.volumePercent, muted: muted)
    }

    func rename(_ speaker: Speaker, to name: String) {
        rpc?.setName(clientID: speaker.id, name: name)
    }

    func setLatency(_ speaker: Speaker, ms: Int) {
        rpc?.setLatency(clientID: speaker.id, latencyMs: ms)
    }

    func stop() {
        tap.stop()
        rpc?.stop()
        advertiser?.stop()
        localClient?.stop()
        server?.stop()
        pipe?.close()
    }

    private func deviceName() -> String { Host.current().localizedName ?? "MacBook" }
}
