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
    }
}

/// Switches the whole window between the role picker and the active role view.
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
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
