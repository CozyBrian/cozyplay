import SwiftUI

/// Join role: browse for parties and connect as a speaker.
struct JoinView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: JoinController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if controller.connectedParty != nil {
                connectedState
            } else {
                browseState
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Join a party").font(.title2.bold())
                Text(controller.statusText).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { appState.backToPicker() } label: {
                Label("Back", systemImage: "chevron.left")
            }
        }
        .padding()
    }

    @ViewBuilder private var browseState: some View {
        if let error = controller.errorText { banner(error) }
        if controller.parties.isEmpty {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Looking for parties on your Wi-Fi…")
                    .font(.title3).foregroundStyle(.secondary)
                Text("Make sure the host is on the same network.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(controller.parties) { party in
                HStack {
                    Image(systemName: "music.note.house.fill").foregroundStyle(.pink)
                    VStack(alignment: .leading) {
                        Text(party.name).font(.headline)
                        Text(party.host).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Join") { controller.join(party) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var connectedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64)).foregroundStyle(.green)
            Text("You’re a speaker!").font(.title.bold())
            if let party = controller.connectedParty {
                Text("Playing “\(party.name)” in sync.")
                    .font(.title3).foregroundStyle(.secondary)
            }
            Button(role: .destructive) { controller.leave() } label: {
                Label("Leave party", systemImage: "xmark.circle")
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
