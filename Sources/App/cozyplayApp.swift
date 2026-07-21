import SwiftUI

@main
struct cozyplayApp: App {
    @StateObject private var appState = AppState()

    init() {
        #if DEBUG
        ClockSyncSpike.startIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}

/// Switches the whole window between the role picker and the active role view.
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        content
            .onAppear {
                #if DEBUG
                // Headless-ish verification hook: COZYPLAY_AUTOHOST=<name> starts
                // hosting immediately (diagnostics land in os.log).
                if appState.mode == .picker,
                   let name = ProcessInfo.processInfo.environment["COZYPLAY_AUTOHOST"] {
                    appState.startHosting(partyName: name.isEmpty ? "Debug Party" : name)
                }
                #endif
            }
    }

    @ViewBuilder private var content: some View {
        switch appState.mode {
        case .picker:
            RolePickerView()
        case .hosting:
            if let host = appState.host {
                HostView(controller: host)
            }
        case .joining:
            if let join = appState.join {
                JoinView(controller: join)
            }
        }
    }
}
