import Foundation
import Network

/// A discoverable cozyplay party (a running host on the LAN).
struct Party: Identifiable, Hashable {
    /// Bonjour instance name, e.g. "Brian's party".
    let name: String
    /// Resolved host address, for display.
    var host: String
    /// The Bonjour service endpoint to connect the stream client to.
    var endpoint: NWEndpoint

    var id: String { "\(name)@\(host)" }
}
