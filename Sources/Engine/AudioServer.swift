import Foundation
import Network
import os.log

/// The host-side engine: owns the party's TCP listener (which both advertises
/// `_cozyplay._tcp` over Bonjour and accepts joiners), fans captured audio out
/// to every client, answers clock-sync pings, and is the authority for the
/// speaker roster.
///
/// Audio path: `ingest` (tap IO queue) → `ChunkAssembler` → hop to the serial
/// net queue → one encoded frame per chunk, sent to every ready session.
final class AudioServer {
    // MARK: Callbacks (delivered on the main queue)

    var onSpeakers: (([Speaker]) -> Void)?
    var onReady: ((UInt16) -> Void)?
    var onError: ((String) -> Void)?
    /// Local playback died/recovered after a device change (nil = recovered).
    var onLocalPlaybackIssue: ((String?) -> Void)?
    /// 1/s engine health snapshot for the diagnostics UI.
    var onDiagnostics: ((HostDiagnostics) -> Void)?

    struct HostDiagnostics {
        var localPlayback: PlaybackEngine.Diagnostics
        var sessions: [SessionInfo]
        struct SessionInfo {
            var name: String
            var inFlightChunks: Int
            var skippedChunks: Int
        }
    }

    let partyName: String
    let localName: String
    let localHostID: String

    /// End-to-end playback delay baked into every chunk's play-at timestamp.
    /// Set from any queue; read on the net queue.
    func setBuffer(ms: Int) {
        netQueue.async {
            self._bufferMs = max(EngineConstants.minBufferMs, min(EngineConstants.maxBufferMs, ms))
            self.localPlayback.partyBufferMs = self._bufferMs
            // Clients don't need to coordinate (the new delay rides the play-at
            // stamps); the broadcast is informational/protocol completeness.
            if let frame = try? WireProtocol.frame(.setBuffer, json: SetBufferMessage(bufferMs: self._bufferMs)) {
                for session in self.sessions where session.hello != nil {
                    session.connection.send(content: frame, completion: .idempotent)
                }
            }
        }
    }
    private var _bufferMs = EngineConstants.defaultBufferMs

    private let netQueue = DispatchQueue(label: "africa.inpathgroup.cozyplay.host.net")
    private var listener: NWListener?
    private var sessions: [ClientSession] = []
    private let assembler = ChunkAssembler()
    private var stopped = false

    /// The host's own speakers, fed by direct injection in the fan-out loop —
    /// same jitter-buffer/servo path as every companion (the servo still
    /// matters locally: the output device's clock differs from mach time).
    /// `IdentityClock` because host timeline time *is* local time here.
    let localPlayback = PlaybackEngine(clock: IdentityClock())

    /// Per-speaker settings, keyed by stable hostID. Persisted to UserDefaults
    /// so a returning Mac gets its name/volume/latency back across parties.
    private struct SpeakerState: Codable {
        var name: String
        var volumePercent = 100
        var muted = false
        var latencyMs = 0
    }
    private var states: [String: SpeakerState] = [:]
    private static let statesDefaultsKey = "cozyplay.speakerStates"

    /// Chunks queued beyond what could still arrive before their deadline are
    /// pointless — skip instead of queueing. bufferMs/20 chunks fill the whole
    /// buffer; +5 gives slack for send-completion latency.
    private var maxInFlightChunks: Int { _bufferMs / 20 + 5 }
    private let saturationLimitNs: UInt64 = 5_000_000_000

    private final class ClientSession {
        let connection: NWConnection
        let reader = FrameReader()
        var hello: HelloMessage?
        var inFlightChunks = 0
        var skippedChunks = 0
        var saturatedSinceNs: UInt64?
        var lastActivityNs = HostClock.nowNs()
        init(connection: NWConnection) { self.connection = connection }
    }

    private var maintenanceTimer: DispatchSourceTimer?
    private let livenessLimitNs: UInt64 = 5_000_000_000

    init(
        partyName: String,
        localName: String,
        localHostID: String,
        bufferMs: Int = EngineConstants.defaultBufferMs
    ) {
        self.partyName = partyName
        self.localName = localName
        self.localHostID = localHostID
        self._bufferMs = max(EngineConstants.minBufferMs, min(EngineConstants.maxBufferMs, bufferMs))
        states = Self.loadStates()
        if states[localHostID] == nil {
            states[localHostID] = SpeakerState(name: "\(localName) (host)")
        }
        localPlayback.onPlaybackIssue = { [weak self] message in
            guard let self else { return }
            if let message {
                self.log.warning("local playback issue: \(message, privacy: .public)")
            } else {
                self.log.info("local playback issue cleared")
            }
            self.onLocalPlaybackIssue?(message)   // already on main
        }
    }

    // MARK: Lifecycle

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp))
        listener.service = NWListener.Service(name: partyName, type: "_cozyplay._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = self.listener?.port?.rawValue ?? 0
                DispatchQueue.main.async { self.onReady?(port) }
            case .failed(let error):
                DispatchQueue.main.async { self.onError?("Couldn't open the party listener: \(error.localizedDescription)") }
            default:
                break
            }
        }
        listener.start(queue: netQueue)
        self.listener = listener

        localPlayback.partyBufferMs = _bufferMs
        do {
            try localPlayback.start()
            // A muted host tile from a previous session is never the intent when
            // starting a NEW party — clear it (volume is preserved).
            if var localState = states[localHostID], localState.muted {
                localState.muted = false
                states[localHostID] = localState
                saveStates()
            }
            if let localState = states[localHostID] {
                localPlayback.volumePercent = localState.volumePercent
                localPlayback.muted = localState.muted
                localPlayback.latencyTrimMs = localState.latencyMs
                log.info("local playback started: volume=\(localState.volumePercent)% muted=\(localState.muted) trim=\(localState.latencyMs)ms")
            }
        } catch {
            // Companions can still join and play; only the host's own speakers are out.
            log.error("local playback failed to start: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.onError?("This Mac's own playback couldn't start: \(error.localizedDescription)")
            }
        }

        // Maintenance (1/s): liveness — pings arrive 1/s per client, so a session
        // silent for 5s is gone even if TCP hasn't noticed — plus a diagnostics
        // snapshot for the UI/logs.
        let timer = DispatchSource.makeTimerSource(queue: netQueue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = HostClock.nowNs()
            for session in self.sessions where session.hello != nil {
                if now - session.lastActivityNs > self.livenessLimitNs {
                    self.drop(session)
                }
            }
            self.emitDiagnostics()
        }
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.resume()
        maintenanceTimer = timer

        pushRoster()
    }

    private func emitDiagnostics() {
        let snapshot = HostDiagnostics(
            localPlayback: localPlayback.snapshotDiagnostics(),
            sessions: sessions.compactMap { session in
                guard let hello = session.hello else { return nil }
                return HostDiagnostics.SessionInfo(
                    name: states[hello.hostID]?.name ?? hello.name,
                    inFlightChunks: session.inFlightChunks,
                    skippedChunks: session.skippedChunks
                )
            }
        )
        let d = snapshot.localPlayback
        log.debug("local: peak=\(d.renderPeak, format: .fixed(precision: 3)) buffered=\(d.bufferedMs)ms err=\(d.servoErrorMs, format: .fixed(precision: 2))ms writes=\(d.writesOK) late=\(d.lateDrops) under=\(d.underrunCycles) invTS=\(d.invalidTimestampCycles) jumps=\(d.jumpCount) restarts=\(d.engineRestarts)/\(d.engineRestartFailures)")
        DispatchQueue.main.async { [weak self] in self?.onDiagnostics?(snapshot) }
    }

    private let log = Logger(subsystem: "africa.inpathgroup.cozyplay", category: "audio-server")

    func stop() {
        netQueue.async { [self] in
            stopped = true
            for session in sessions {
                session.connection.send(content: WireProtocol.frame(.bye), completion: .idempotent)
                session.connection.cancel()
            }
            sessions.removeAll()
            listener?.cancel()
            listener = nil
            maintenanceTimer?.cancel()
            maintenanceTimer = nil
            localPlayback.stop()
        }
    }

    // MARK: Audio ingest (tap IO queue)

    /// Feed converted S16LE capture data; `firstFrameHostNs` is the capture
    /// host time of the data's first frame.
    func ingest(_ s16Data: Data, firstFrameHostNs: UInt64) {
        let chunks = assembler.ingest(s16Data, firstFrameHostNs: firstFrameHostNs)
        guard !chunks.isEmpty else { return }
        netQueue.async { [weak self] in
            self?.fanOut(chunks)
        }
    }

    // MARK: Speaker controls (any queue; roster authority lives here)

    func setVolume(clientID: String, percent: Int, muted: Bool) {
        updateState(clientID) { state in
            state.volumePercent = max(0, min(100, percent))
            state.muted = muted
        } push: { state in
            try? WireProtocol.frame(.setVolume, json: SetVolumeMessage(percent: state.volumePercent, muted: state.muted))
        }
    }

    func setName(clientID: String, name: String) {
        updateState(clientID) { state in
            state.name = name
        } push: { state in
            try? WireProtocol.frame(.setName, json: SetNameMessage(name: state.name))
        }
    }

    func setLatency(clientID: String, latencyMs: Int) {
        updateState(clientID) { state in
            state.latencyMs = max(-100, min(100, latencyMs))
        } push: { state in
            try? WireProtocol.frame(.setLatency, json: SetLatencyMessage(latencyMs: state.latencyMs))
        }
    }

    private func updateState(
        _ clientID: String,
        _ mutate: @escaping (inout SpeakerState) -> Void,
        push makeFrame: @escaping (SpeakerState) -> Data?
    ) {
        netQueue.async { [self] in
            guard var state = states[clientID] else { return }
            mutate(&state)
            states[clientID] = state
            saveStates()
            if clientID == localHostID {
                localPlayback.volumePercent = state.volumePercent
                localPlayback.muted = state.muted
                localPlayback.latencyTrimMs = state.latencyMs
            } else if let session = sessions.first(where: { $0.hello?.hostID == clientID }),
                      let frame = makeFrame(state) {
                session.connection.send(content: frame, completion: .idempotent)
            }
            pushRoster()
        }
    }

    // MARK: Sessions (net queue)

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        let session = ClientSession(connection: connection)
        sessions.append(session)
        connection.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session else { return }
            switch state {
            case .failed, .cancelled:
                self.remove(session)
            default:
                break
            }
        }
        receiveLoop(session)
        connection.start(queue: netQueue)
    }

    private func remove(_ session: ClientSession) {
        sessions.removeAll { $0 === session }
        pushRoster()
    }

    private func drop(_ session: ClientSession) {
        session.connection.cancel()
        remove(session)
    }

    private func receiveLoop(_ session: ClientSession) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak session] data, _, isComplete, error in
            guard let self, let session else { return }
            if let data { session.reader.append(data) }
            do {
                while let frame = try session.reader.next() {
                    self.handle(frame.type, frame.payload, from: session)
                }
            } catch {
                self.drop(session)
                return
            }
            if isComplete || error != nil {
                self.drop(session)
                return
            }
            self.receiveLoop(session)
        }
    }

    private func handle(_ type: WireProtocol.FrameType, _ payload: Data, from session: ClientSession) {
        session.lastActivityNs = HostClock.nowNs()
        switch type {
        case .ping:
            guard let t0 = WireProtocol.decodePing(payload) else { return }
            let t1 = HostClock.nowNs()
            session.connection.send(
                content: WireProtocol.pongFrame(t0: t0, t1: t1, t2: HostClock.nowNs()),
                completion: .idempotent
            )
        case .hello:
            guard let hello = try? WireProtocol.decodeJSON(HelloMessage.self, from: payload) else {
                drop(session)
                return
            }
            session.hello = hello
            // Rejoining Macs keep their previous settings; first-timers get defaults.
            let state = states[hello.hostID] ?? SpeakerState(name: hello.name)
            states[hello.hostID] = state
            saveStates()
            let welcome = WelcomeMessage(
                bufferMs: _bufferMs,
                sampleRate: EngineConstants.sampleRate,
                channels: EngineConstants.channels,
                volumePercent: state.volumePercent,
                muted: state.muted,
                latencyMs: state.latencyMs
            )
            if let frame = try? WireProtocol.frame(.welcome, json: welcome) {
                session.connection.send(content: frame, completion: .idempotent)
            }
            pushRoster()
        case .bye:
            drop(session)
        default:
            break
        }
    }

    // MARK: Fan-out (net queue)

    private func fanOut(_ chunks: [ChunkAssembler.Chunk]) {
        for chunk in chunks {
            let playAtHostNs = chunk.captureNs &+ UInt64(_bufferMs) * 1_000_000
            let audio = AudioChunk(
                seq: chunk.seq,
                playAtHostNs: playAtHostNs,
                frameCount: UInt16(EngineConstants.chunkFrames),
                samples: chunk.samples
            )
            let frame = WireProtocol.frame(.audio, payload: audio.encodePayload())
            for session in sessions where session.hello != nil {
                send(frame, to: session)
            }
            localPlayback.ingest(audio)
        }
    }

    /// Slow-client policy: skip chunks for a session with too much unsent audio
    /// (they'd miss their deadline anyway; the client's timeline self-heals),
    /// and drop the session entirely if it stays saturated.
    private func send(_ frame: Data, to session: ClientSession) {
        if session.inFlightChunks >= maxInFlightChunks {
            session.skippedChunks += 1
            let now = HostClock.nowNs()
            if let since = session.saturatedSinceNs {
                if now - since > saturationLimitNs { drop(session) }
            } else {
                session.saturatedSinceNs = now
            }
            return
        }
        session.saturatedSinceNs = nil
        session.inFlightChunks += 1
        session.connection.send(content: frame, completion: .contentProcessed { [weak session] _ in
            session?.inFlightChunks -= 1
        })
    }

    // MARK: Roster (net queue)

    /// Safe to call from any queue: state is always read on the net queue.
    /// Speakers that joined this party and left stay listed (grey tile) so the
    /// host can see who dropped; speakers from *previous* parties don't appear
    /// until they say hello again.
    private func pushRoster() {
        netQueue.async { [weak self] in
            guard let self else { return }
            var list: [Speaker] = []
            if let localState = self.states[self.localHostID] {
                list.append(self.speaker(id: self.localHostID, state: localState, connected: true, isThisMac: true))
            }
            let connectedIDs = Set(self.sessions.compactMap { $0.hello?.hostID })
            for id in connectedIDs {
                guard let state = self.states[id] else { continue }
                list.append(self.speaker(id: id, state: state, connected: true, isThisMac: false))
            }
            for id in self.seenThisParty.subtracting(connectedIDs) where id != self.localHostID {
                guard let state = self.states[id] else { continue }
                list.append(self.speaker(id: id, state: state, connected: false, isThisMac: false))
            }
            self.seenThisParty.formUnion(connectedIDs)
            let snapshot = list.sorted { ($0.isThisMac ? 0 : 1, $0.displayName) < ($1.isThisMac ? 0 : 1, $1.displayName) }
            DispatchQueue.main.async { self.onSpeakers?(snapshot) }
        }
    }

    private var seenThisParty: Set<String> = []

    // MARK: Persistence

    private static func loadStates() -> [String: SpeakerState] {
        guard let data = UserDefaults.standard.data(forKey: statesDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: SpeakerState].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveStates() {
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: Self.statesDefaultsKey)
        }
    }

    private func speaker(id: String, state: SpeakerState, connected: Bool, isThisMac: Bool) -> Speaker {
        Speaker(
            id: id,
            name: state.name,
            host: state.name,
            volumePercent: state.volumePercent,
            isMuted: state.muted,
            latencyMs: state.latencyMs,
            isConnected: connected,
            isThisMac: isThisMac
        )
    }
}
