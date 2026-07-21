import SwiftUI

/// One speaker in the party grid: name, connection status, volume, mute.
struct DeviceTileView: View {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(speaker.isConnected ? .green : .gray)
                    .frame(width: 9, height: 9)
                Image(systemName: speaker.isThisMac ? "laptopcomputer.and.arrow.down" : "laptopcomputer")
                Spacer()
                if speaker.isThisMac {
                    Text("This Mac").font(.caption2).foregroundStyle(.secondary)
                }
            }

            nameField

            HStack(spacing: 8) {
                Button {
                    controller.setMuted(speaker, muted: !speaker.isMuted)
                } label: {
                    Image(systemName: speaker.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                Slider(value: $volume, in: 0...100) { editing in
                    if !editing { controller.setVolume(speaker, percent: Int(volume)) }
                }
                Text("\(Int(volume))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: speaker.volumePercent) { _, newValue in
            if newValue != Int(volume) { volume = Double(newValue) }
        }
    }

    @ViewBuilder private var nameField: some View {
        if isEditingName {
            TextField("Name", text: $draftName, onCommit: commitName)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
        } else {
            Text(speaker.displayName)
                .font(.headline)
                .lineLimit(1)
                .onTapGesture { isEditingName = true }
        }
    }

    private func commitName() {
        isEditingName = false
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { controller.rename(speaker, to: trimmed) }
    }
}
