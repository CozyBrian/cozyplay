import Foundation

/// A discoverable cozyplay party (a running host on the LAN).
struct Party: Identifiable, Hashable {
    /// Bonjour instance name, e.g. "Brian's party".
    let name: String
    /// Resolved host address (IPv4/IPv6 or hostname) of the master.
    var host: String
    /// The host engine's listening port, read from the Bonjour TXT record.
    var port: Int?

    var id: String { "\(name)@\(host)" }
}
