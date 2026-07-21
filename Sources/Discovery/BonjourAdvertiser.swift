import Foundation
import Network

/// Advertises this master as a discoverable cozyplay party over Bonjour
/// (`_cozyplay._tcp`). We publish our own record rather than relying on the
/// macOS snapserver build to advertise `_snapcast._tcp` (unconfirmed).
///
/// The listener itself does nothing with incoming connections — snapserver already
/// listens on 1704/1705. The record just makes the party findable; the TXT entries
/// carry the well-known Snapcast ports.
final class BonjourAdvertiser {
    private let partyName: String
    private let streamPort: Int
    private let controlPort: Int
    private let queue = DispatchQueue(label: "africa.inpathgroup.cozyplay.advertise")
    private var listener: NWListener?

    init(partyName: String, streamPort: Int = 1704, controlPort: Int = 1705) {
        self.partyName = partyName
        self.streamPort = streamPort
        self.controlPort = controlPort
    }

    func start() {
        do {
            let listener = try NWListener(using: .tcp)
            let txt = NWTXTRecord([
                "stream": String(streamPort),
                "ctrl": String(controlPort),
            ])
            listener.service = NWListener.Service(
                name: partyName,
                type: "_cozyplay._tcp",
                txtRecord: txt
            )
            listener.newConnectionHandler = { connection in
                connection.cancel() // we don't accept these; snapserver handles real traffic
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("cozyplay: failed to advertise party: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
