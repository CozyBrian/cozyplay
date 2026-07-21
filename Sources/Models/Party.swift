import Foundation

/// A discoverable cozyplay party (a running host on the LAN).
struct Party: Identifiable, Hashable {
    /// Bonjour instance name, e.g. "Brian's party".
    let name: String
    /// Resolved host address (IPv4/IPv6 or hostname) of the master.
    var host: String
    /// Snapcast stream port on the master (default 1704).
    var streamPort: Int = 1704
    /// Snapcast JSON-RPC control port on the master (default 1705).
    var controlPort: Int = 1705

    var id: String { "\(name)@\(host)" }
}
