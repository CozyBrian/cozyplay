import Foundation
import Combine

/// Drives the "Join a party" role: browses Bonjour for hosts and, once the user
/// picks one, launches a snapclient pointed at the master so this laptop plays the
/// synced stream.
@MainActor
final class JoinController: ObservableObject {
    @Published var parties: [Party] = []
    @Published var connectedParty: Party?
    @Published var statusText = "Looking for parties…"
    @Published var errorText: String?

    private let browser = BonjourBrowser()
    private var client: SnapcastClient?

    func startBrowsing() {
        browser.onParties = { [weak self] parties in
            guard let self else { return }
            self.parties = parties
            if self.connectedParty == nil {
                self.statusText = parties.isEmpty
                    ? "Looking for parties…"
                    : "Found \(parties.count) part\(parties.count == 1 ? "y" : "ies")"
            }
        }
        browser.start()
    }

    func join(_ party: Party) {
        errorText = nil
        do {
            let client = SnapcastClient(host: party.host, displayName: deviceName())
            try client.start()
            self.client = client
            connectedParty = party
            statusText = "Connected to “\(party.name)” — playing in sync"
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func leave() {
        client?.stop()
        client = nil
        connectedParty = nil
        statusText = parties.isEmpty ? "Looking for parties…" : "Found \(parties.count)"
    }

    func stop() {
        browser.stop()
        client?.stop()
        client = nil
    }

    private func deviceName() -> String { Host.current().localizedName ?? "MacBook" }
}
