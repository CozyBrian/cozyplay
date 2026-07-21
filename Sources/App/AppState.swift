import Foundation
import Combine

/// Top-level app mode. cozyplay is one app; the user picks a role at launch.
enum AppMode: Equatable {
    case picker
    case hosting
    case joining
}

/// Root observable app state. Owns the per-role controllers, created lazily
/// when the user chooses "Host" or "Join" so we never start audio capture or
/// open network sockets until a role is actually selected.
@MainActor
final class AppState: ObservableObject {
    @Published var mode: AppMode = .picker

    private(set) var host: HostController?
    private(set) var join: JoinController?

    func startHosting(partyName: String) {
        let controller = HostController(partyName: partyName)
        host = controller
        mode = .hosting
        controller.start()
    }

    func startJoining() {
        let controller = JoinController()
        join = controller
        mode = .joining
        controller.startBrowsing()
    }

    func backToPicker() {
        host?.stop()
        join?.stop()
        host = nil
        join = nil
        mode = .picker
    }
}
