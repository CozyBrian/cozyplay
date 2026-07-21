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
    @Published var diagnostics: StreamClient.StreamDiagnostics?

    private let browser = BonjourBrowser()
    private var client: StreamClient?

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
        client?.disconnect()

        let client = StreamClient(
            endpoint: party.endpoint,
            hostID: HostIdentity.stableID(),
            displayName: deviceName()
        )
        client.onState = { [weak self] state in
            guard let self, self.connectedParty == party else { return }
            switch state {
            case .idle:
                break
            case .connecting, .waitingForWelcome:
                self.statusText = "Connecting to “\(party.name)”…"
            case .playing:
                self.statusText = "Connected to “\(party.name)” — playing in sync"
            case .reconnecting:
                self.statusText = "Reconnecting to “\(party.name)”…"
            case .ended(let reason):
                self.errorText = reason
                self.connectedParty = nil
                self.statusText = self.parties.isEmpty ? "Looking for parties…" : "Found \(self.parties.count)"
            }
        }
        client.onDiagnostics = { [weak self] snapshot in
            self?.diagnostics = snapshot
        }
        client.connect()
        self.client = client
        connectedParty = party
        statusText = "Connecting to “\(party.name)”…"
    }

    func leave() {
        client?.disconnect()
        client = nil
        connectedParty = nil
        diagnostics = nil
        statusText = parties.isEmpty ? "Looking for parties…" : "Found \(parties.count)"
    }

    func stop() {
        browser.stop()
        client?.disconnect()
        client = nil
    }

    private func deviceName() -> String { AppSettings.deviceName() }
}
