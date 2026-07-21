import Foundation

/// One speaker in the party — a Snapcast client as reported by `Server.GetStatus`.
struct Speaker: Identifiable, Hashable {
    /// Snapcast client id (stable host id; we set it via snapclient --hostID).
    let id: String
    /// Friendly, user-editable name (Snapcast `config.name`, falling back to the host).
    var name: String
    /// Machine host name reported by the client.
    var host: String
    /// 0...100
    var volumePercent: Int
    var isMuted: Bool
    /// Per-client latency trim in milliseconds (Snapcast `config.latency`).
    var latencyMs: Int
    var isConnected: Bool
    /// True for the speaker that is this same machine (the local/master client).
    var isThisMac: Bool = false

    var displayName: String { name.isEmpty ? host : name }
}
