import Foundation
import Combine

/// Drives the "Join a party" role: browses Bonjour for hosts and, once the user
/// picks one, connects the native stream client so this laptop plays the synced
/// stream.
@MainActor
final class JoinController: ObservableObject {
    @Published var parties: [Party] = []
    @Published var connectedParty: Party?
    @Published var statusText = "Looking for parties…"
    @Published var errorText: String?

    private let browser = BonjourBrowser()
    // TODO(M-2): StreamClient — connect, clock sync, jitter buffer, playback.

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
        // TODO(M-2): connect a StreamClient to party.host:party.port and surface
        // its state changes here; until then joining is discovery-only.
        connectedParty = party
        statusText = "Joined “\(party.name)” — native playback engine not built yet"
    }

    func leave() {
        connectedParty = nil
        statusText = parties.isEmpty ? "Looking for parties…" : "Found \(parties.count)"
    }

    func stop() {
        browser.stop()
    }

    private func deviceName() -> String { Host.current().localizedName ?? "MacBook" }
}
