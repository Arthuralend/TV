import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: TVStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var reminders: Reminders
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ChannelsView()
                .tabItem { Label("Channels", systemImage: "tv") }
                .tag(0)
            GuideView()
                .tabItem { Label("TV Guide", systemImage: "calendar") }
                .tag(1)
            FavoritesView()
                .tabItem { Label("Favorites", systemImage: "star.fill") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        .fullScreenCover(isPresented: $player.isPresented) {
            PlayerScreen()
                .environmentObject(store)
                .environmentObject(player)
                .environmentObject(reminders)
        }
        .alert(Text("Notifications are off"), isPresented: $reminders.deniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow notifications for TV in Settings to get reminders before programmes start.")
        }
    }
}
