import SwiftUI

/// Host role: now-playing meter + a grid of speaker tiles for everyone in the party.
struct HostView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: HostController
    @AppStorage(AppSettings.showDiagnosticsKey) private var showDiagnostics = false
    @State private var showingPartySettings = false

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.partyName).font(.title2.bold())
                Text(controller.statusText).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            NowPlayingMeter(level: controller.level, active: controller.isCapturing)
            Button {
                showingPartySettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Party settings")
            .popover(isPresented: $showingPartySettings, arrowEdge: .bottom) {
                PartySettingsPopover(controller: controller)
            }
            Button(role: .destructive) { appState.backToPicker() } label: {
                Label("End party", systemImage: "stop.circle")
            }
        }
        .padding()
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            if let error = controller.errorText {
                banner(error)
            }
            if controller.speakers.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(controller.speakers) { speaker in
                        DeviceTileView(speaker: speaker, controller: controller)
                    }
                }
                .padding()
            }
            if showDiagnostics, let diagnostics = controller.diagnostics {
                HostDiagnosticsPanel(diagnostics: diagnostics)
                    .padding([.horizontal, .bottom])
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text("Waiting for laptops to join…")
                .font(.title3).foregroundStyle(.secondary)
            Text("On another MacBook, open cozyplay and tap “Join a party”.")
                .font(.callout).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
        }
        .padding()
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top])
    }
}

/// Live party settings (gear popover on the host).
private struct PartySettingsPopover: View {
    @ObservedObject var controller: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playback delay").font(.headline)
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(controller.bufferMs) },
                        set: { controller.setBuffer(ms: Int($0 / 10) * 10) }
                    ),
                    in: Double(EngineConstants.minBufferMs)...Double(EngineConstants.maxBufferMs)
                )
                .frame(width: 220)
                Text("\(controller.bufferMs) ms")
                    .font(.body.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            }
            Text("Applies immediately to every speaker. Raise it if audio drops out on busy Wi-Fi; lower it for tighter video sync.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// A simple animated level bar for the master's captured audio.
struct NowPlayingMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: active ? "waveform" : "waveform.slash")
                .foregroundStyle(active ? .green : .secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green)
                        .frame(width: geo.size.width * CGFloat(max(0.02, min(1, level))))
                }
            }
            .frame(width: 120, height: 8)
        }
    }
}
