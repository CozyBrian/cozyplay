#if DEBUG
import Foundation
import Network

/// M-1 field harness: measures clock-sync quality between two Macs over real
/// WiFi before any audio exists. Debug builds only; not part of any user flow.
///
/// On the host Mac (terminal):
///     COZYPLAY_CLOCKSPIKE=host  ./cozyplay.app/Contents/MacOS/cozyplay
/// On the client Mac:
///     COZYPLAY_CLOCKSPIKE=client COZYPLAY_SPIKE_HOST=192.168.x.x \
///         ./cozyplay.app/Contents/MacOS/cozyplay
///
/// The client prints one line per pong (offset / RTT / converged). Let it run
/// 10+ minutes on party WiFi — offset wander should stay within ±1ms — then
/// repeat while a large file copy saturates the network.
enum ClockSyncSpike {
    static let port: NWEndpoint.Port = 7205
    private static let queue = DispatchQueue(label: "africa.inpathgroup.cozyplay.clockspike")

    static func startIfRequested() {
        switch ProcessInfo.processInfo.environment["COZYPLAY_CLOCKSPIKE"] {
        case "host":
            runHost()
        case "client":
            guard let host = ProcessInfo.processInfo.environment["COZYPLAY_SPIKE_HOST"] else {
                print("[clockspike] set COZYPLAY_SPIKE_HOST=<host mac ip>")
                return
            }
            runClient(host: host)
        default:
            break
        }
    }

    // MARK: Host: answer pings

    private static var listener: NWListener?
    private static var hostConnections: [NWConnection] = []

    private static func runHost() {
        do {
            let listener = try NWListener(using: tcpParameters(), on: port)
            listener.newConnectionHandler = { connection in
                print("[clockspike] client connected: \(connection.endpoint)")
                hostConnections.append(connection)
                receiveLoop(connection, reader: FrameReader()) { type, payload in
                    guard type == .ping, let t0 = WireProtocol.decodePing(payload) else { return }
                    let t1 = HostClock.nowNs()
                    let t2 = HostClock.nowNs()
                    connection.send(
                        content: WireProtocol.pongFrame(t0: t0, t1: t1, t2: t2),
                        completion: .idempotent
                    )
                }
                connection.start(queue: queue)
            }
            listener.start(queue: queue)
            self.listener = listener
            print("[clockspike] host answering pings on :\(port)")
        } catch {
            print("[clockspike] listener failed: \(error)")
        }
    }

    // MARK: Client: ping, log offset

    private static var clientConnection: NWConnection?
    private static var pingTimer: DispatchSourceTimer?

    private static func runClient(host: String) {
        let clock = SyncClock()
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: port, using: tcpParameters()
        )
        clientConnection = connection

        connection.stateUpdateHandler = { state in
            print("[clockspike] connection: \(state)")
            guard case .ready = state else { return }
            // Burst of 20 pings at 50ms, then 1/s steady state.
            var sent = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler {
                sent += 1
                if sent == 20 { timer.schedule(deadline: .now() + 1, repeating: 1.0) }
                connection.send(
                    content: WireProtocol.pingFrame(t0: clock.makePingT0()),
                    completion: .idempotent
                )
            }
            timer.schedule(deadline: .now(), repeating: 0.05)
            timer.resume()
            pingTimer = timer
        }

        receiveLoop(connection, reader: FrameReader()) { type, payload in
            guard type == .pong, let pong = WireProtocol.decodePong(payload) else { return }
            clock.ingestPong(t0: pong.t0, t1: pong.t1, t2: pong.t2)
            let d = clock.diagnostics
            let drift = clock.estimatedDriftNsPerSec.map { String(format: " drift=%+.0fns/s", $0) } ?? ""
            print(String(
                format: "[clockspike] offset=%+.3fms minRTT=%.3fms samples=%d converged=%@%@",
                d.offsetMs, d.minRttMs, d.samples, d.converged ? "YES" : "no", drift
            ))
        }
        connection.start(queue: queue)
    }

    // MARK: Shared

    private static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private static func receiveLoop(
        _ connection: NWConnection,
        reader: FrameReader,
        handler: @escaping (WireProtocol.FrameType, Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data { reader.append(data) }
            do {
                while let frame = try reader.next() {
                    handler(frame.type, frame.payload)
                }
            } catch {
                print("[clockspike] protocol error: \(error)")
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                print("[clockspike] connection ended: \(String(describing: error))")
                connection.cancel()
                return
            }
            receiveLoop(connection, reader: reader, handler: handler)
        }
    }
}
#endif
