import SwiftUI

/// The standard macOS Settings window (⌘,).
struct SettingsView: View {
    @AppStorage(AppSettings.displayNameOverrideKey) private var displayName = ""
    @AppStorage(AppSettings.defaultBufferMsKey) private var defaultBufferMs = EngineConstants.defaultBufferMs
    @AppStorage(AppSettings.showDiagnosticsKey) private var showDiagnostics = false
    @AppStorage(AppSettings.keepSourceAudibleKey) private var keepSourceAudible = false

    var body: some View {
        Form {
            Section("General") {
                TextField("Speaker name", text: $displayName, prompt: Text(Host.current().localizedName ?? "MacBook"))
                Text("How this Mac appears in parties. A rename made from the host's speaker grid overrides this.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Playback delay") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(clampedBuffer) },
                                set: { defaultBufferMs = Int($0 / 10) * 10 }
                            ),
                            in: Double(EngineConstants.minBufferMs)...Double(EngineConstants.maxBufferMs)
                        )
                        Text("\(clampedBuffer) ms")
                            .font(.body.monospacedDigit())
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Text("Delay between the host's audio and every speaker. Lower is snappier; raise it if audio drops out on busy Wi-Fi. Applies to new parties (the host can also change it live from the gear menu).")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Show diagnostics", isOn: $showDiagnostics)
                Text("Engine health readouts in the party views: clock offset, buffer fill, drops, underruns.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Troubleshooting") {
                Toggle("Keep source audio audible on the host", isOn: $keepSourceAudible)
                Text("Normally the host mutes the original app and plays the delayed, synced copy so it lines up with the other speakers. This switch skips the mute — the host will sound ahead of everyone (doubled audio). Only for debugging silent-host issues. Takes effect the next time you host.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var clampedBuffer: Int {
        max(EngineConstants.minBufferMs, min(EngineConstants.maxBufferMs, defaultBufferMs))
    }
}

// MARK: - Diagnostics panels (shared by Host/Join views)

struct HostDiagnosticsPanel: View {
    let diagnostics: AudioServer.HostDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Engine diagnostics").font(.caption.bold()).foregroundStyle(.secondary)
            PlaybackDiagnosticsGrid(d: diagnostics.localPlayback, title: "This Mac")
            ForEach(diagnostics.sessions, id: \.name) { session in
                Text("\(session.name): \(session.inFlightChunks) in flight, \(session.skippedChunks) skipped")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StreamDiagnosticsPanel: View {
    let diagnostics: StreamClient.StreamDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Engine diagnostics").font(.caption.bold()).foregroundStyle(.secondary)
            Text(String(
                format: "clock %+.2fms · RTT %.2fms · %@",
                diagnostics.offsetMs, diagnostics.minRttMs,
                diagnostics.clockConverged ? "locked" : "syncing"
            ))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            PlaybackDiagnosticsGrid(d: diagnostics.playback, title: "Playback")
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PlaybackDiagnosticsGrid: View {
    let d: PlaybackEngine.Diagnostics
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(
                format: "%@: peak %.2f · buffered %dms · servo %+.2fms",
                title, d.renderPeak, d.bufferedMs, d.servoErrorMs
            ))
            Text(String(
                format: "writes %d · late %d · underruns %d · jumps %d · badTS %d · restarts %d/%d",
                d.writesOK, d.lateDrops, d.underrunCycles, d.jumpCount,
                d.invalidTimestampCycles, d.engineRestarts, d.engineRestartFailures
            ))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}
