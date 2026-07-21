import Foundation
import Network

/// Minimal client for Snapcast's control API: newline-delimited JSON-RPC 2.0
/// over raw TCP (default port 1705).
///
/// Responsibilities:
///   - connect / reconnect to snapserver
///   - fetch the client list via `Server.GetStatus` and map it to `[Speaker]`
///   - push control commands: `Client.SetVolume`, `Client.SetName`, `Client.SetLatency`
///   - refresh on any server-pushed notification (`Client.On*`, `Server.OnUpdate`, …)
///
/// Callbacks are delivered on `callbackQueue` (main by default).
final class SnapcastRPC {
    private let host: String
    private let port: Int
    private let callbackQueue: DispatchQueue

    /// Called with the current speaker list whenever status is (re)fetched.
    var onSpeakers: (([Speaker]) -> Void)?
    /// Called with human-readable connection state changes.
    var onConnectionChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "africa.inpathgroup.cozyplay.rpc")
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextID = 1
    private var isStopped = false

    init(host: String, port: Int = 1705, callbackQueue: DispatchQueue = .main) {
        self.host = host
        self.port = port
        self.callbackQueue = callbackQueue
    }

    // MARK: Lifecycle

    func start() {
        isStopped = false
        connect()
    }

    func stop() {
        isStopped = true
        queue.async {
            self.connection?.cancel()
            self.connection = nil
        }
    }

    private func connect() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 1705
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emitConnection(true)
                self.receiveLoop()
                self.getStatus()
            case .failed, .cancelled:
                self.emitConnection(false)
                self.scheduleReconnect()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard !isStopped else { return }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.connect()
        }
    }

    // MARK: Commands

    func setVolume(clientID: String, percent: Int, muted: Bool) {
        send(method: "Client.SetVolume",
             params: ["id": clientID,
                      "volume": ["percent": max(0, min(100, percent)), "muted": muted]])
    }

    func setName(clientID: String, name: String) {
        send(method: "Client.SetName", params: ["id": clientID, "name": name])
    }

    func setLatency(clientID: String, latencyMs: Int) {
        send(method: "Client.SetLatency", params: ["id": clientID, "latency": latencyMs])
    }

    func getStatus() {
        send(method: "Server.GetStatus", params: [:])
    }

    // MARK: Sending

    private func send(method: String, params: [String: Any]) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { payload["params"] = params }
        payload["id"] = nextID
        nextID += 1
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(contentsOf: [0x0d, 0x0a]) // \r\n
        queue.async {
            self.connection?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    // MARK: Receiving

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainLines()
            }
            if isComplete || error != nil {
                self.emitConnection(false)
                self.scheduleReconnect()
                return
            }
            self.receiveLoop()
        }
    }

    private func drainLines() {
        while let nl = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            handle(message: obj)
        }
    }

    private func handle(message: [String: Any]) {
        // Response to Server.GetStatus.
        if let result = message["result"] as? [String: Any],
           let server = result["server"] as? [String: Any] {
            let speakers = SnapcastRPC.parseSpeakers(server: server)
            callbackQueue.async { self.onSpeakers?(speakers) }
            return
        }
        // Server-pushed notification → just refresh the whole status.
        if message["method"] is String {
            getStatus()
        }
    }

    /// Flatten `server.groups[].clients[]` into `[Speaker]`.
    static func parseSpeakers(server: [String: Any]) -> [Speaker] {
        var speakers: [Speaker] = []
        let groups = server["groups"] as? [[String: Any]] ?? []
        for group in groups {
            let clients = group["clients"] as? [[String: Any]] ?? []
            for client in clients {
                guard let id = client["id"] as? String else { continue }
                let config = client["config"] as? [String: Any] ?? [:]
                let volume = config["volume"] as? [String: Any] ?? [:]
                let hostDict = client["host"] as? [String: Any] ?? [:]
                let hostName = hostDict["name"] as? String ?? id
                let name = (config["name"] as? String) ?? ""
                speakers.append(Speaker(
                    id: id,
                    name: name,
                    host: hostName,
                    volumePercent: volume["percent"] as? Int ?? 100,
                    isMuted: volume["muted"] as? Bool ?? false,
                    latencyMs: config["latency"] as? Int ?? 0,
                    isConnected: client["connected"] as? Bool ?? false
                ))
            }
        }
        return speakers
    }

    private func emitConnection(_ connected: Bool) {
        callbackQueue.async { self.onConnectionChange?(connected) }
    }
}
