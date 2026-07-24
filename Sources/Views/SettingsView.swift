import SwiftUI

/// The standard macOS Settings window (Command-,).
struct SettingsView: View {
    @AppStorage(AppSettings.displayNameOverrideKey) private var displayName = ""
    @AppStorage(AppSettings.defaultPartyNameKey) private var defaultPartyName = ""
    @AppStorage(AppSettings.defaultBufferMsKey) private var defaultBufferMs = EngineConstants.defaultBufferMs
    @AppStorage(AppSettings.showDiagnosticsKey) private var showDiagnostics = false
    @AppStorage(AppSettings.keepSourceAudibleKey) private var keepSourceAudible = false

    @State private var bufferSliderMs = 0.0

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("Device name") {
                    TextField(Host.current().localizedName ?? "MacBook", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                Text("How this Mac appears to everyone in the room.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Party name") {
                    TextField("\(AppSettings.deviceName())’s party", text: $defaultPartyName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                Text("Used when this Mac hosts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Playback") {
                LabeledContent("Default delay") {
                    Text("\(Int(bufferSliderMs)) ms")
                        .monospacedDigit()
                }

                Slider(
                    value: $bufferSliderMs,
                    in: Double(EngineConstants.minBufferMs)...Double(EngineConstants.maxBufferMs),
                    step: 10
                )
                .accessibilityLabel("Default delay")
                .accessibilityValue("\(Int(bufferSliderMs)) milliseconds")

                Text("Lower values feel more immediate. Raise the delay if audio drops out on busy Wi-Fi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced") {
                Toggle(isOn: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show diagnostics")
                        Text("Display clock, buffer, and stream health inside party views.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $keepSourceAudible) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep source audio audible")
                        Text("Troubleshooting only. The host will sound ahead of every other speaker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 470)
        .onAppear {
            bufferSliderMs = Double(clampedBuffer)
        }
        .onChange(of: bufferSliderMs) { _, newValue in
            defaultBufferMs = Int(newValue)
        }
    }

    private var clampedBuffer: Int {
        max(EngineConstants.minBufferMs, min(EngineConstants.maxBufferMs, defaultBufferMs))
    }
}

// MARK: - Diagnostics panels (shared by Host/Join views)

struct HostDiagnosticsPanel: View {
    let diagnostics: AudioServer.HostDiagnostics

    var body: some View {
        diagnosticsShell {
            PlaybackDiagnosticsGrid(d: diagnostics.localPlayback, title: "This Mac")
            ForEach(diagnostics.sessions, id: \.name) { session in
                Text("\(session.name): \(session.inFlightChunks) in flight, \(session.skippedChunks) skipped")
            }
        }
    }
}

struct StreamDiagnosticsPanel: View {
    let diagnostics: StreamClient.StreamDiagnostics

    var body: some View {
        diagnosticsShell {
            Text(String(
                format: "clock %+.2fms · RTT %.2fms · %@",
                diagnostics.offsetMs, diagnostics.minRttMs,
                diagnostics.clockConverged ? "locked" : "syncing"
            ))
            PlaybackDiagnosticsGrid(d: diagnostics.playback, title: "Playback")
        }
    }
}

private func diagnosticsShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Label("Engine diagnostics", systemImage: "waveform.path.ecg")
            .font(CozyFont.sectionTitle)
            .foregroundStyle(CozyColor.textPrimary)
        content()
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(CozyColor.textSecondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cozyCard()
}

struct PlaybackDiagnosticsGrid: View {
    let d: PlaybackEngine.Diagnostics
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(
                format: "%@: peak %.2f · buffered %dms · servo %+.2fms · outLat %dms",
                title, d.renderPeak, d.bufferedMs, d.servoErrorMs, d.outputLatencyMs
            ))
            Text(String(
                format: "writes %d · late %d · underruns %d · jumps %d · badTS %d · restarts %d/%d",
                d.writesOK, d.lateDrops, d.underrunCycles, d.jumpCount,
                d.invalidTimestampCycles, d.engineRestarts, d.engineRestartFailures
            ))
        }
    }
}
