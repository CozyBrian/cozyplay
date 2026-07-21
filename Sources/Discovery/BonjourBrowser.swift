import Foundation
import Network

/// Browses the LAN for cozyplay parties (`_cozyplay._tcp`) and resolves each to a
/// reachable host so a companion can connect its stream client to the master.
///
/// Discovered services are resolved to an IP by briefly opening an NWConnection and
/// reading the remote endpoint — NWBrowser results alone don't carry an address.
final class BonjourBrowser {
    /// Delivered on the main queue whenever the party list changes.
    var onParties: (([Party]) -> Void)?

    private let queue = DispatchQueue(label: "africa.inpathgroup.cozyplay.browse")
    private var browser: NWBrowser?
    private var parties: [String: Party] = [:]        // keyed by Bonjour instance name
    private var resolvers: [String: NWConnection] = [:]

    func start() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_cozyplay._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        parties.removeAll()
    }

    private func handle(results: Set<NWBrowser.Result>) {
        // Drop parties that vanished.
        let liveNames: Set<String> = Set(results.compactMap { Self.instanceName($0.endpoint) })
        for name in parties.keys where !liveNames.contains(name) {
            parties[name] = nil
            resolvers[name]?.cancel()
            resolvers[name] = nil
        }
        // Resolve newly-seen parties.
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            if parties[name] == nil && resolvers[name] == nil {
                resolve(endpoint: result.endpoint, name: name)
            }
        }
        emit()
    }

    private func resolve(endpoint: NWEndpoint, name: String) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        resolvers[name] = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state,
               let remote = conn.currentPath?.remoteEndpoint,
               case let .hostPort(host, _) = remote {
                self.parties[name] = Party(name: name, host: Self.hostString(host))
                self.emit()
                conn.cancel()
                self.resolvers[name] = nil
            } else if case .failed = state {
                conn.cancel()
                self.resolvers[name] = nil
            }
        }
        conn.start(queue: queue)
    }

    private func emit() {
        let list = parties.values.sorted { $0.name < $1.name }
        DispatchQueue.main.async { self.onParties?(list) }
    }

    private static func instanceName(_ endpoint: NWEndpoint) -> String? {
        if case let .service(name, _, _, _) = endpoint { return name }
        return nil
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let n, _): return n
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        case .ipv6(let a): return "\(a)".components(separatedBy: "%").first ?? "\(a)"
        @unknown default: return "\(host)"
        }
    }
}
