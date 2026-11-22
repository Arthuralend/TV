import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var store: TVStore
    @Environment(\.playerRef) private var player
    @State private var path: [Channel] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                let favorites = store.favoriteChannels
                let recents = store.recentChannels
                if favorites.isEmpty && recents.isEmpty {
                    EmptyStateView(icon: "star", title: "No favorites yet",
                                   message: "Swipe left on a channel or touch and hold it to add it to Favorites.")
                } else {
                    List {
                        if !favorites.isEmpty {
                            Section {
                                ForEach(favorites) { c in
                                    ChannelRow(channel: c, onGuide: { path.append(c) }) { player?.open(c, queue: favorites) }
                                        .channelActions(c, store: store) { path.append(c) }
                                }
                            } header: {
                                Text("Favorites")
                            }
                        }
                        if !recents.isEmpty {
                            Section {
                                ForEach(recents) { c in
                                    ChannelRow(channel: c, onGuide: { path.append(c) }) { player?.open(c, queue: recents) }
                                        .channelActions(c, store: store) { path.append(c) }
                                }
                            } header: {
                                HStack {
                                    Text("Recently Watched")
                                    Spacer()
                                    Button("Clear") { store.clearRecents() }.font(.footnote)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle(Text("Favorites"))
            .navigationDestination(for: Channel.self) { ScheduleView(channel: $0) }
        }
    }
}
