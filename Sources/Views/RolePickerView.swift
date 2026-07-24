import SwiftUI

/// Launch screen: the console with two rack slots — host a party or join one.
/// Device and party names live behind the toolbar gear, not inline.
struct RolePickerView: View {
    @EnvironmentObject private var appState: AppState
    // Bound so the party-name preview refreshes while the popover edits them.
    @AppStorage(AppSettings.displayNameOverrideKey) private var deviceNameOverride = ""
    @AppStorage(AppSettings.defaultPartyNameKey) private var storedPartyName = ""
    @State private var showingIdentitySettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: CozySpacing.xLarge) {
                header

                VStack(spacing: 0) {
                    hostSlot
                    CozyRackSeparator(leadingInset: 64)
                    joinSlot
                }
                .cozyRack()

                Label("No account or internet connection required", systemImage: "lock")
                    .font(CozyFont.caption)
                    .foregroundStyle(CozyColor.textSecondary.opacity(0.75))
            }
            .frame(maxWidth: 560)
            .padding(CozySpacing.xLarge)
            .padding(.top, CozySpacing.large)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Cozyplay")
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }

            ToolbarItem(placement: .primaryAction) {
                Button("Identity Settings", systemImage: "gearshape") {
                    showingIdentitySettings.toggle()
                }
                .help("Device and party name")
                .popover(isPresented: $showingIdentitySettings, arrowEdge: .bottom) {
                    IdentityPopover()
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: CozySpacing.small) {
            CozyIconChip(systemImage: "hifispeaker.2.fill", size: 56)
            Text("Cozyplay")
                .font(CozyFont.hero)
                .foregroundStyle(CozyColor.textPrimary)
            Text("Play audio through every Mac in the room.")
                .font(CozyFont.detail)
                .foregroundStyle(CozyColor.textSecondary)
        }
    }

    private var hostSlot: some View {
        HStack(spacing: CozySpacing.small) {
            CozyIconChip(systemImage: "waveform")

            VStack(alignment: .leading, spacing: 2) {
                Text("Host a party")
                    .font(CozyFont.sectionTitle)
                    .foregroundStyle(CozyColor.textPrimary)
                Text("This Mac captures the audio and keeps every speaker in sync.")
                    .font(CozyFont.caption)
                    .foregroundStyle(CozyColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("“\(AppSettings.partyName())”")
                    .font(CozyFont.caption)
                    .foregroundStyle(CozyColor.textSecondary.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: CozySpacing.xSmall)

            Button("Start Hosting", systemImage: "play.fill", action: startHosting)
                .buttonStyle(.borderedProminent)
        }
        .padding(CozySpacing.medium)
    }

    private var joinSlot: some View {
        HStack(spacing: CozySpacing.small) {
            CozyIconChip(systemImage: "dot.radiowaves.left.and.right", color: CozyColor.success)

            VStack(alignment: .leading, spacing: 2) {
                Text("Join as a speaker")
                    .font(CozyFont.sectionTitle)
                    .foregroundStyle(CozyColor.textPrimary)
                Text("Find parties on your local network.")
                    .font(CozyFont.caption)
                    .foregroundStyle(CozyColor.textSecondary)
            }

            Spacer(minLength: CozySpacing.xSmall)

            Button("Find Nearby", systemImage: "magnifyingglass", action: appState.startJoining)
                .buttonStyle(.bordered)
        }
        .padding(CozySpacing.medium)
    }

    private func startHosting() {
        appState.startHosting(partyName: AppSettings.partyName())
    }
}

/// Toolbar-gear popover: the two names this Mac introduces itself with.
private struct IdentityPopover: View {
    @AppStorage(AppSettings.displayNameOverrideKey) private var deviceName = ""
    @AppStorage(AppSettings.defaultPartyNameKey) private var partyName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: CozySpacing.medium) {
            VStack(alignment: .leading, spacing: CozySpacing.xSmall) {
                Text("Device name")
                    .font(CozyFont.sectionTitle)
                    .foregroundStyle(CozyColor.textPrimary)
                TextField(Host.current().localizedName ?? "MacBook", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
                Text("How this Mac appears to everyone in the room.")
                    .font(CozyFont.caption)
                    .foregroundStyle(CozyColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: CozySpacing.xSmall) {
                Text("Party name")
                    .font(CozyFont.sectionTitle)
                    .foregroundStyle(CozyColor.textPrimary)
                TextField("\(AppSettings.deviceName())’s party", text: $partyName)
                    .textFieldStyle(.roundedBorder)
                Text("Used when this Mac hosts.")
                    .font(CozyFont.caption)
                    .foregroundStyle(CozyColor.textSecondary)
            }
        }
        .padding(CozySpacing.large)
        .frame(width: 320)
    }
}
