import Foundation

/// One speaker in the party, as reported by the host's roster.
struct Speaker: Identifiable, Hashable {
    /// Stable per-machine id (`HostIdentity.stableID()`).
    let id: String
    /// Friendly, user-editable name (falls back to the host name).
    var name: String
    /// Machine host name reported by the client.
    var host: String
    /// 0...100
    var volumePercent: Int
    var isMuted: Bool
    /// Per-speaker latency trim in milliseconds (renders earlier by this much).
    var latencyMs: Int
    var isConnected: Bool
    /// True for the speaker that is this same machine (the local/master client).
    var isThisMac: Bool = false

    var displayName: String { name.isEmpty ? host : name }
}
