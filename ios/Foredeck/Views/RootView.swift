import SwiftUI
import ForedeckCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = Tab.session

    private enum Tab: Hashable {
        case session, anchor, settings
    }

    var body: some View {
        Group {
            if model.isPaired {
                paired
            } else {
                PairingView(settings: model.settings, boatStore: model.boatStore)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Deck.accent(night: model.settings.nightMode))
        .alert(
            "Problem",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onOpenURL { url in
            guard let invitation = BoatInvitation(url: url) else { return }
            model.boatStore.pair(name: invitation.boatName, code: invitation.code)
        }
    }

    private var paired: some View {
        TabView(selection: $selection) {
            NavigationStack {
                SessionView(settings: model.settings)
                    .navigationTitle("Crew")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { sessionToolbar }
            }
            .tabItem { Label("Crew", systemImage: "person.2.wave.2") }
            .tag(Tab.session)

            NavigationStack {
                AnchorView(settings: model.settings)
                    .navigationTitle(model.anchorState.mode.value.label)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Anchor", systemImage: "mappin.and.ellipse") }
            .tag(Tab.anchor)

            NavigationStack {
                SettingsView(settings: model.settings, boatStore: model.boatStore)
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
    }

    @ToolbarContentBuilder
    private var sessionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if model.isSessionActive {
                Button("Leave", role: .destructive) { model.endSession() }
            } else {
                Button("Join") { model.startSession() }
                    .fontWeight(.semibold)
            }
        }
    }
}
