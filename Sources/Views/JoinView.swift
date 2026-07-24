import SwiftUI

/// Join role: browse for parties and connect as a speaker.
struct JoinView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: JoinController
    @AppStorage(AppSettings.showDiagnosticsKey) private var showDiagnostics = false

    private var isConnected: Bool { controller.connectedParty != nil }

    var body: some View {
        Group {
            if isConnected {
                connectedState
            } else {
                browseState
            }
        }
        .navigationTitle(isConnected ? "Now Playing" : "Nearby Parties")
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: appState.backToPicker)
                    .help("Back to the start screen")
            }
        }
    }

    // MARK: - Browse

    private var browseState: some View {
        ScrollView {
            VStack(spacing: CozySpacing.large) {
                if let error = controller.errorText {
                    CozyErrorBanner(text: error)
                }

                browseRail

                VStack(spacing: CozySpacing.small) {
                    CozySectionHeader(
                        title: "On Your Network",
                        detail: controller.parties.isEmpty ? nil : "\(controller.parties.count) available"
                    )
                    partyRack
                }
            }
            .frame(maxWidth: 640)
            .padding(CozySpacing.large)
            .frame(maxWidth: .infinity)
        }
    }

    private var browseRail: some View {
        VStack(alignment: .leading, spacing: CozySpacing.xSmall) {
            HStack(alignment: .firstTextBaseline) {
                Text("Nearby Parties")
                    .font(CozyFont.railTitle)
                    .foregroundStyle(CozyColor.textPrimary)
                Spacer()
                CozyStatusChip(text: "Scanning", color: CozyColor.tint)
            }
            Text("Parties on the same Wi-Fi appear here automatically.")
                .font(CozyFont.caption)
                .foregroundStyle(CozyColor.textSecondary)
        }
        .cozyCard(padding: CozySpacing.large)
    }

    private var partyRack: some View {
        VStack(spacing: 0) {
            if controller.parties.isEmpty {
                scanningRow
            } else {
                ForEach(Array(controller.parties.enumerated()), id: \.element.id) { index, party in
                    if index > 0 {
                        CozyRackSeparator(leadingInset: 64)
                    }
                    PartyRow(party: party, controller: controller)
                        .transition(.opacity)
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: controller.parties.map(\.id))
        .cozyRack()
    }

    private var scanningRow: some View {
        HStack(spacing: CozySpacing.small) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Scanning local network")
            Text("Looking for parties…")
                .font(CozyFont.detail)
                .foregroundStyle(CozyColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(CozySpacing.medium)
    }

    // MARK: - Connected

    private var connectedState: some View {
        ScrollView {
            VStack(spacing: CozySpacing.large) {
                if let error = controller.errorText {
                    CozyErrorBanner(text: error)
                }

                receiverFace

                if showDiagnostics, let diagnostics = controller.diagnostics {
                    StreamDiagnosticsPanel(diagnostics: diagnostics)
                }
            }
            .frame(maxWidth: 640)
            .padding(CozySpacing.large)
            .frame(maxWidth: .infinity)
        }
    }

    /// Full-window "receiver face": glanceable from across the room.
    private var receiverFace: some View {
        VStack(spacing: CozySpacing.medium) {
            ConnectedWaveform()

            VStack(spacing: 6) {
                Text(controller.connectedParty?.name ?? "Party")
                    .font(CozyFont.hero)
                    .foregroundStyle(CozyColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text("In sync with \(controller.connectedParty?.host ?? "the host")")
                    .font(CozyFont.detail)
                    .foregroundStyle(CozyColor.textSecondary)
            }

            Button(action: controller.leave) {
                Label("Leave Party", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(CozyColor.accent)
            .padding(.top, CozySpacing.xSmall)
        }
        .padding(CozySpacing.xLarge * 1.5)
        .frame(maxWidth: .infinity, minHeight: 380)
        .adaptiveGlass(radius: CozyRadius.large)
    }
}

private struct ConnectedWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(CozyColor.success)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            .frame(width: 64, height: 64)
            .background(CozyColor.success.opacity(0.12), in: .rect(cornerRadius: 20))
            .accessibilityHidden(true)
    }
}

private struct PartyRow: View {
    let party: Party
    @ObservedObject var controller: JoinController

    var body: some View {
        HStack(spacing: CozySpacing.small) {
            CozyIconChip(systemImage: "music.note.house.fill")

            VStack(alignment: .leading, spacing: 3) {
                Text(party.name)
                    .font(CozyFont.sectionTitle)
                    .foregroundStyle(CozyColor.textPrimary)
                Label(party.host, systemImage: "wifi")
                    .font(CozyFont.caption)
                    .foregroundStyle(CozyColor.textSecondary)
            }
            Spacer()
            Button("Join", systemImage: "arrow.right", action: join)
                .buttonStyle(.borderedProminent)
        }
        .padding(CozySpacing.medium)
        .rackRowHover()
    }

    private func join() {
        controller.join(party)
    }
}
