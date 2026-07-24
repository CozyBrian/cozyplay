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
            NavigationStack {
                RootView()
            }
            .environmentObject(appState)
            .tint(CozyColor.tint)
            .fontDesign(.rounded)
            .frame(minWidth: 720, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 620)

        Settings {
            SettingsView()
                .tint(CozyColor.tint)
                .fontDesign(.rounded)
        }
    }
}

/// Switches the whole window between the role picker and the active role view.
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            content
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CozyColor.background)
        .animation(.smooth(duration: 0.25), value: appState.mode)
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
