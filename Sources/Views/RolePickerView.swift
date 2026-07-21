import SwiftUI

/// Launch screen: choose to host a party or join one.
struct RolePickerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var partyName = "\(Host.current().localizedName ?? "My")’s party"

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 6) {
                Text("cozyplay")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("Turn every MacBook in the room into one big synced speaker system.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 20) {
                hostCard
                joinCard
            }
            .frame(maxWidth: 640)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hostCard: some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 56))
            Text("Host a party").font(.title2.bold())
            Text("Play music here; everyone else becomes a speaker.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("Party name", text: $partyName)
                .textFieldStyle(.roundedBorder)
            Button {
                appState.startHosting(partyName: partyName.trimmingCharacters(in: .whitespaces))
            } label: {
                Text("Start hosting").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(partyName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }

    private var joinCard: some View {
        VStack(spacing: 16) {
            Text("🔊").font(.system(size: 56))
            Text("Join a party").font(.title2.bold())
            Text("Become a speaker for a party someone nearby is hosting.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button {
                appState.startJoining()
            } label: {
                Text("Find a party").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}
