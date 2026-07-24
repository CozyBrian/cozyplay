import SwiftUI

/// Host role: a receiver-style rail with the live meter, then the speaker rack.
struct HostView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: HostController
    @AppStorage(AppSettings.showDiagnosticsKey) private var showDiagnostics = false
    @State private var showingPartySettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: CozySpacing.large) {
                if let error = controller.errorText {
                    CozyErrorBanner(text: error)
                }

                receiverRail

                VStack(spacing: CozySpacing.small) {
                    CozySectionHeader(
                        title: "Speakers",
                        detail: controller.speakers.isEmpty
                            ? "Waiting for devices"
                            : "\(controller.speakers.count) connected"
                    )
                    speakerRack
                }

                if showDiagnostics, let diagnostics = controller.diagnostics {
                    HostDiagnosticsPanel(diagnostics: diagnostics)
                }
            }
            .frame(maxWidth: 760)
            .padding(CozySpacing.large)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(controller.partyName)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("Cozyplay")
                    .font(CozyFont.caption)
                    .kerning(1.1)
                    .textCase(.uppercase)
                    .foregroundStyle(CozyColor.textSecondary.opacity(0.85))
                    .padding(.horizontal, CozySpacing.small)
                    .accessibilityHidden(true)
            }

            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button("Party Settings", systemImage: "slider.horizontal.3") {
                    showingPartySettings.toggle()
                }
                .help("Party-wide playback delay")
                .popover(isPresented: $showingPartySettings, arrowEdge: .bottom) {
                    PartySettingsPopover(controller: controller)
                }

                Button(role: .destructive, action: appState.backToPicker) {
                    Label("End Party", systemImage: "stop.fill")
                        .foregroundStyle(CozyColor.accent)
                }
                .help("Stop hosting and disconnect every speaker")
            }
        }
    }

    /// The console faceplate: party name, live chip, level meter, status line.
    private var receiverRail: some View {
        VStack(alignment: .leading, spacing: CozySpacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Text(controller.partyName)
                    .font(CozyFont.railTitle)
                    .foregroundStyle(CozyColor.textPrimary)
                    .lineLimit(1)
                Spacer()
                CozyStatusChip(
                    text: controller.isCapturing ? "Live" : "Starting",
                    color: controller.isCapturing ? CozyColor.success : CozyColor.tint
                )
            }

            CozyVUMeter(level: controller.level, active: controller.isCapturing)

            Text(railCaption)
                .font(CozyFont.caption)
                .foregroundStyle(CozyColor.textSecondary)
                .monospacedDigit()
        }
        .cozyCard(padding: CozySpacing.large)
    }

    private var railCaption: String {
        guard controller.isCapturing else { return "Preparing audio capture…" }
        let count = controller.speakers.count
        let speakers = count == 1 ? "1 speaker" : "\(count) speakers"
        return "\(controller.bufferMs) ms delay · \(speakers)"
    }

    private var speakerRack: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.speakers.enumerated()), id: \.element.id) { index, speaker in
                if index > 0 {
                    CozyRackSeparator(leadingInset: 64)
                }
                DeviceTileView(speaker: speaker, controller: controller)
                    .transition(.opacity)
            }

            if !controller.speakers.isEmpty {
                CozyRackSeparator(leadingInset: 64)
            }
            inviteRow
        }
        .animation(.smooth(duration: 0.25), value: controller.speakers.map(\.id))
        .cozyRack()
    }

    private var inviteRow: some View {
        HStack(spacing: CozySpacing.small) {
            CozyIconChip(systemImage: "wave.3.right", color: CozyColor.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add another Mac")
                    .font(CozyFont.detail)
                    .foregroundStyle(CozyColor.textPrimary)
                Text("Open Cozyplay on it and choose Find Nearby.")
                    .font(CozyFont.caption)
                    .foregroundStyle(CozyColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(CozySpacing.medium)
        .accessibilityElement(children: .combine)
    }
}

private struct PartySettingsPopover: View {
    @ObservedObject var controller: HostController
    @State private var bufferMs: Double

    init(controller: HostController) {
        self.controller = controller
        _bufferMs = State(initialValue: Double(controller.bufferMs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CozySpacing.medium) {
            HStack {
                Text("Playback delay")
                    .font(CozyFont.sectionTitle)
                    .foregroundStyle(CozyColor.textPrimary)
                Spacer()
                Text("\(Int(bufferMs)) ms")
                    .font(CozyFont.body)
                    .monospacedDigit()
                    .foregroundStyle(CozyColor.textSecondary)
            }

            Slider(
                value: $bufferMs,
                in: Double(EngineConstants.minBufferMs)...Double(EngineConstants.maxBufferMs),
                step: 10
            ) { editing in
                if !editing {
                    controller.setBuffer(ms: Int(bufferMs))
                }
            }
            .accessibilityLabel("Playback delay")
            .accessibilityValue("\(Int(bufferMs)) milliseconds")

            Text("Raise the delay if audio drops out on busy Wi-Fi. Lower it for tighter video sync.")
                .font(CozyFont.caption)
                .foregroundStyle(CozyColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CozySpacing.large)
        .frame(width: 340)
    }
}
