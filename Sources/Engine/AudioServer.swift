import Foundation
import Network

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

    let partyName: String
    let localName: String
    let localHostID: String

    /// End-to-end playback delay baked into every chunk's play-at timestamp.
    /// Set from any queue; read on the net queue.
    func setBuffer(ms: Int) {
        netQueue.async {
            self._bufferMs = max(EngineConstants.minBufferMs, min(EngineConstants.maxBufferMs, ms))
            // TODO(M-4): broadcast SetBufferMessage to clients.
        }
    }
    private var _bufferMs = EngineConstants.defaultBufferMs

    private let netQueue = DispatchQueue(label: "africa.inpathgroup.cozyplay.host.net")
    private var listener: NWListener?
    private var sessions: [ClientSession] = []
    private let assembler = ChunkAssembler()
    private var stopped = false

    /// Per-speaker settings, keyed by stable hostID. Kept across rejoins so a
    /// returning Mac gets its name/volume back. (M-4: persisted + pushed to clients.)
    private struct SpeakerState {
        var name: String
        var volumePercent = 100
        var muted = false
        var latencyMs = 0
    }
    private var states: [String: SpeakerState] = [:]

    private let maxInFlightChunks = 25            // ~500ms of audio stuck in flight
    private let saturationLimitNs: UInt64 = 5_000_000_000

    private final class ClientSession {
        let connection: NWConnection
        let reader = FrameReader()
        var hello: HelloMessage?
        var inFlightChunks = 0
        var saturatedSinceNs: UInt64?
        init(connection: NWConnection) { self.connection = connection }
    }

    init(partyName: String, localName: String, localHostID: String) {
        self.partyName = partyName
        self.localName = localName
        self.localHostID = localHostID
        states[localHostID] = SpeakerState(name: "\(localName) (host)")
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
        pushRoster()
    }

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
        updateState(clientID) { $0.volumePercent = max(0, min(100, percent)); $0.muted = muted }
    }

    func setName(clientID: String, name: String) {
        updateState(clientID) { $0.name = name }
    }

    func setLatency(clientID: String, latencyMs: Int) {
        updateState(clientID) { $0.latencyMs = latencyMs }
    }

    private func updateState(_ clientID: String, _ mutate: @escaping (inout SpeakerState) -> Void) {
        netQueue.async { [self] in
            guard var state = states[clientID] else { return }
            mutate(&state)
            states[clientID] = state
            // TODO(M-4): push the change to the affected client connection.
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
            // TODO(M-3): localPlayback.ingest(audio) — host's own speakers.
        }
    }

    /// Slow-client policy: skip chunks for a session with too much unsent audio
    /// (they'd miss their deadline anyway; the client's timeline self-heals),
    /// and drop the session entirely if it stays saturated.
    private func send(_ frame: Data, to session: ClientSession) {
        if session.inFlightChunks >= maxInFlightChunks {
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
    private func pushRoster() {
        netQueue.async { [weak self] in
            guard let self else { return }
            var list: [Speaker] = []
            if let localState = self.states[self.localHostID] {
                list.append(self.speaker(id: self.localHostID, state: localState, connected: true, isThisMac: true))
            }
            for session in self.sessions {
                guard let hello = session.hello, let state = self.states[hello.hostID] else { continue }
                list.append(self.speaker(id: hello.hostID, state: state, connected: true, isThisMac: false))
            }
            let snapshot = list
            DispatchQueue.main.async { self.onSpeakers?(snapshot) }
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
