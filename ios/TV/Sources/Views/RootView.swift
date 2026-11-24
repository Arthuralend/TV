import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: TVStore
    @EnvironmentObject private var reminders: Reminders
    @State private var tab = 0
    #if DEBUG
    @Environment(\.playerRef) private var playerRef
    #endif

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
        .modifier(PlayerPresenter())
        #if DEBUG
        .task { await screenshotSetup() }
        #endif
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

#if DEBUG
extension RootView {
    /// App Store screenshots in CI (debug builds only): launched with `-screenshotScreen <name>`.
    @MainActor
    func screenshotSetup() async {
        guard let screen = UserDefaults.standard.string(forKey: "screenshotScreen"), screen != "welcome" else { return }
        if store.playlists.isEmpty {
            store.add(Playlist(name: "TV", kind: .url, source: "https://arthuralend.github.io/TV/demo.m3u"))
        }
        for _ in 0..<60 where store.channels.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000) }
        switch screen {
        case "settings": tab = 3
        case "player": if let c = store.channels.first { playerRef?.open(c, queue: store.channels) }
        default: tab = 0
        }
    }
}
#endif

/// Only this modifier observes the player, so the tabs are not rebuilt on every player event.
private struct PlayerPresenter: ViewModifier {
    @EnvironmentObject private var store: TVStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var reminders: Reminders

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $player.isPresented) {
            PlayerScreen()
                .environmentObject(store)
                .environmentObject(player)
                .environmentObject(reminders)
        }
    }
}
