import SwiftUI

/// One channel strip in the speaker rack: name, status, fader, mute, sync trim.
struct DeviceTileView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let speaker: Speaker
    @ObservedObject var controller: HostController

    @State private var volume: Double
    @State private var isEditingName = false
    @State private var draftName: String

    init(speaker: Speaker, controller: HostController) {
        self.speaker = speaker
        self.controller = controller
        _volume = State(initialValue: Double(speaker.volumePercent))
        _draftName = State(initialValue: speaker.displayName)
    }

    var body: some View {
        VStack(spacing: CozySpacing.small) {
            identityRow
            faderRow
        }
        .padding(CozySpacing.medium)
        .rackRowHover()
        .onChange(of: speaker.volumePercent) { _, newValue in
            if newValue != Int(volume) {
                volume = Double(newValue)
            }
        }
    }

    private var identityRow: some View {
        HStack(spacing: CozySpacing.small) {
            CozyIconChip(
                systemImage: speaker.isThisMac ? "laptopcomputer.and.arrow.down" : "laptopcomputer",
                color: statusColor
            )

            nameControl

            Spacer(minLength: CozySpacing.xSmall)

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(CozyFont.caption)
                    .foregroundStyle(CozyColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var faderRow: some View {
        HStack(spacing: CozySpacing.small) {
            Button(
                speaker.isMuted ? "Unmute" : "Mute",
                systemImage: speaker.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                action: toggleMute
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(speaker.isMuted ? CozyColor.accent : CozyColor.textSecondary)

            Slider(value: $volume, in: 0...100) { editing in
                if !editing {
                    controller.setVolume(speaker, percent: Int(volume))
                }
            }
            .accessibilityLabel("Volume for \(speaker.displayName)")
            .accessibilityValue("\(Int(volume)) percent")
            .disabled(speaker.isMuted)

            Text(speaker.isMuted ? "Muted" : "\(Int(volume))%")
                .font(CozyFont.caption)
                .monospacedDigit()
                .foregroundStyle(speaker.isMuted ? CozyColor.accent : CozyColor.textSecondary)
                .contentTransition(reduceMotion ? .identity : .numericText(value: volume))
                .animation(.smooth(duration: 0.15), value: volume)
                .frame(width: 44, alignment: .trailing)

            Divider()
                .frame(height: 16)

            trimCluster
        }
    }

    private var trimCluster: some View {
        HStack(spacing: CozySpacing.xSmall) {
            Text(speaker.latencyMs == 0 ? "Aligned" : String(format: "%+d ms", speaker.latencyMs))
                .font(CozyFont.caption)
                .monospacedDigit()
                .foregroundStyle(CozyColor.textSecondary)
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(speaker.latencyMs)))
                .animation(.smooth(duration: 0.15), value: speaker.latencyMs)

            Stepper("Sync trim for \(speaker.displayName)") {
                controller.setLatency(speaker, ms: min(100, speaker.latencyMs + 5))
            } onDecrement: {
                controller.setLatency(speaker, ms: max(-100, speaker.latencyMs - 5))
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .help("Nudge this speaker if it sounds slightly out of sync with the room.")
    }

    @ViewBuilder
    private var nameControl: some View {
        if isEditingName {
            TextField("Speaker name", text: $draftName, onCommit: commitName)
                .textFieldStyle(.roundedBorder)
                .font(CozyFont.sectionTitle)
                .frame(maxWidth: 260)
        } else {
            Button(action: beginRenaming) {
                Text(speaker.displayName)
                    .font(CozyFont.sectionTitle)
                    .foregroundStyle(CozyColor.textPrimary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Rename speaker")
            .accessibilityLabel("Rename \(speaker.displayName)")
        }
    }

    private var statusColor: Color {
        if speaker.isThisMac { return CozyColor.tint }
        return speaker.isConnected ? CozyColor.success : CozyColor.textSecondary
    }

    private var statusText: String {
        if speaker.isThisMac { return "This Mac" }
        return speaker.isConnected ? "Connected" : "Offline"
    }

    private func toggleMute() {
        controller.setMuted(speaker, muted: !speaker.isMuted)
    }

    private func beginRenaming() {
        draftName = speaker.displayName
        isEditingName = true
    }

    private func commitName() {
        isEditingName = false
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            controller.rename(speaker, to: trimmed)
        }
    }
}
