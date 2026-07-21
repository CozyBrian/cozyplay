import Foundation
import Network
import os.log

/// The join-side engine: connects to a party's Bonjour service endpoint,
/// handshakes, keeps the clock synced with pings, and feeds received audio
/// into the local `PlaybackEngine`. Reconnects with backoff if the
/// connection drops; playback renders silence in the meantime.
final class StreamClient {
    enum ClientState: Equatable {
        case idle
        case connecting
        case waitingForWelcome
        case playing
        case reconnecting(attempt: Int)
        case ended(String)
    }

    /// Delivered on the main queue.
    var onState: ((ClientState) -> Void)?
    /// ~1/s engine health snapshot for the diagnostics UI (main queue).
    var onDiagnostics: ((StreamDiagnostics) -> Void)?

    struct StreamDiagnostics {
        var offsetMs: Double
        var minRttMs: Double
        var clockConverged: Bool
        var playback: PlaybackEngine.Diagnostics
    }

    private let endpoint: NWEndpoint
    private let hostID: String
    private let displayName: String

    private let netQueue = DispatchQueue(label: "africa.inpathgroup.cozyplay.client.net")
    private let log = Logger(subsystem: "africa.inpathgroup.cozyplay", category: "stream-client")

    private var connection: NWConnection?
    private var reader = FrameReader()
    private let clock = SyncClock()
    private let playback: PlaybackEngine
    private var pingTimer: DispatchSourceTimer?
    private var pongsSeen = 0
    private var reconnectAttempt = 0
    private var closed = false

    init(endpoint: NWEndpoint, hostID: String, displayName: String) {
        self.endpoint = endpoint
        self.hostID = hostID
        self.displayName = displayName
        self.playback = PlaybackEngine(clock: clock)
    }

    func connect() {
        netQueue.async { [self] in
            guard !closed else { return }
            openConnection()
        }
    }

    func disconnect() {
        netQueue.async { [self] in
            closed = true
            pingTimer?.cancel()
            pingTimer = nil
            connection?.send(content: WireProtocol.frame(.bye), completion: .idempotent)
            connection?.cancel()
            connection = nil
            playback.stop()
            setState(.idle)
        }
    }

    // MARK: Connection (net queue)

    private func openConnection() {
        setState(reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt))

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        reader = FrameReader()
        clock.reset()
        clock.onDesync = { [weak self] in
            guard let self else { return }
            self.log.info("clock step detected — hard resync")
            self.playback.hardResync()
        }

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            switch state {
            case .ready:
                self.reconnectAttempt = 0
                self.sendHello()
                self.startPings()
                self.setState(.waitingForWelcome)
            case .failed(let error):
                self.log.info("connection failed: \(error.localizedDescription)")
                self.scheduleReconnect()
            default:
                break
            }
        }
        receiveLoop(connection)
        connection.start(queue: netQueue)
    }

    private func scheduleReconnect() {
        guard !closed else { return }
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        reconnectAttempt += 1
        let delay = min(8.0, pow(2.0, Double(reconnectAttempt - 1)))
        setState(.reconnecting(attempt: reconnectAttempt))
        netQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed else { return }
            self.openConnection()
        }
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, connection === self.connection else { return }
            if let data { self.reader.append(data) }
            do {
                while let frame = try self.reader.next() {
                    self.handle(frame.type, frame.payload)
                }
            } catch {
                self.log.error("protocol error: \(String(describing: error))")
                self.scheduleReconnect()
                return
            }
            if isComplete || error != nil {
                self.scheduleReconnect()
                return
            }
            self.receiveLoop(connection)
        }
    }

    // MARK: Frames (net queue)

    private func handle(_ type: WireProtocol.FrameType, _ payload: Data) {
        switch type {
        case .welcome:
            guard let welcome = try? WireProtocol.decodeJSON(WelcomeMessage.self, from: payload) else { return }
            playback.volumePercent = welcome.volumePercent
            playback.muted = welcome.muted
            playback.latencyTrimMs = welcome.latencyMs
            playback.partyBufferMs = welcome.bufferMs
            do {
                try playback.start()
                setState(.playing)
            } catch {
                setState(.ended("Couldn't start audio playback: \(error.localizedDescription)"))
            }
        case .audio:
            guard let chunk = AudioChunk.decode(payload: payload) else { return }
            playback.ingest(chunk)
        case .pong:
            guard let pong = WireProtocol.decodePong(payload) else { return }
            clock.ingestPong(t0: pong.t0, t1: pong.t1, t2: pong.t2)
            pongsSeen += 1
            if pongsSeen >= 20 || pongsSeen % 5 == 0 {   // 1/s steady state; sparse during the burst
                let d = clock.diagnostics
                let snapshot = StreamDiagnostics(
                    offsetMs: d.offsetMs,
                    minRttMs: d.minRttMs,
                    clockConverged: d.converged,
                    playback: playback.snapshotDiagnostics()
                )
                let p = snapshot.playback
                log.debug("sync offset=\(d.offsetMs, format: .fixed(precision: 3))ms minRTT=\(d.minRttMs, format: .fixed(precision: 3))ms converged=\(d.converged) peak=\(p.renderPeak, format: .fixed(precision: 3)) buffered=\(p.bufferedMs)ms err=\(p.servoErrorMs, format: .fixed(precision: 2))ms late=\(p.lateDrops) under=\(p.underrunCycles) jumps=\(p.jumpCount)")
                DispatchQueue.main.async { [onDiagnostics] in onDiagnostics?(snapshot) }
            }
        case .setVolume:
            guard let msg = try? WireProtocol.decodeJSON(SetVolumeMessage.self, from: payload) else { return }
            playback.volumePercent = msg.percent
            playback.muted = msg.muted
        case .setLatency:
            guard let msg = try? WireProtocol.decodeJSON(SetLatencyMessage.self, from: payload) else { return }
            playback.latencyTrimMs = msg.latencyMs
        case .setBuffer:
            // Buffer changes ride the new play-at stamps; we only track the
            // value so the output-latency clamp knows how far ahead it may run.
            guard let msg = try? WireProtocol.decodeJSON(SetBufferMessage.self, from: payload) else { return }
            playback.partyBufferMs = msg.bufferMs
        case .setName:
            break   // name is host-side display state
        case .bye:
            closed = true
            pingTimer?.cancel()
            pingTimer = nil
            connection?.cancel()
            connection = nil
            playback.stop()
            setState(.ended("The party ended"))
        default:
            break
        }
    }

    private func sendHello() {
        let hello = HelloMessage(hostID: hostID, name: displayName, proto: Int(WireProtocol.version))
        if let frame = try? WireProtocol.frame(.hello, json: hello) {
            connection?.send(content: frame, completion: .idempotent)
        }
    }

    /// Burst of 20 pings at 50ms on connect (fast convergence), then 1/s
    /// steady state (doubles as liveness).
    private func startPings() {
        pingTimer?.cancel()
        var sent = 0
        let timer = DispatchSource.makeTimerSource(queue: netQueue)
        timer.setEventHandler { [weak self, weak timer] in
            guard let self, let connection = self.connection else { return }
            sent += 1
            if sent == 20 {
                timer?.schedule(deadline: .now() + 1, repeating: 1.0)
            }
            connection.send(
                content: WireProtocol.pingFrame(t0: self.clock.makePingT0()),
                completion: .idempotent
            )
        }
        timer.schedule(deadline: .now(), repeating: 0.05)
        timer.resume()
        pingTimer = timer
    }

    private func setState(_ state: ClientState) {
        DispatchQueue.main.async { [onState] in onState?(state) }
    }
}
