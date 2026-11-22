import SwiftUI

struct ChannelsView: View {
    @EnvironmentObject private var store: TVStore
    @EnvironmentObject private var player: PlayerController
    @State private var group = ChannelGroup.all
    @State private var search = ""
    @State private var path: [Channel] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.playlists.isEmpty {
                    WelcomeView()
                } else {
                    content
                }
            }
            .background(Theme.background)
            .navigationTitle(store.selectedPlaylist?.name ?? String(localized: "Channels"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !store.playlists.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) { PlaylistMenu() }
                }
            }
            .navigationDestination(for: Channel.self) { ScheduleView(channel: $0) }
        }
        .onChange(of: store.selectedPlaylistID) { _ in group = .all }
    }

    private var groups: [ChannelGroup] { [.all] + store.groups.map { .named($0) } }

    private var list: [Channel] {
        store.channels(in: group.name, search: search)
    }

    private var content: some View {
        VStack(spacing: 0) {
            StatusBanner()
            if store.groups.count > 1 {
                ChipBar(items: groups, selection: $group) { $0.title }
            }
            let items = list
            if items.isEmpty && !store.isLoading {
                if search.isEmpty {
                    EmptyStateView(icon: "tv", title: "No channels", message: "Pull down to refresh the playlist.")
                } else {
                    EmptyStateView(icon: "magnifyingglass", title: "Nothing found")
                }
            } else {
                List(items) { c in
                    ChannelRow(channel: c, onGuide: { path.append(c) }) {
                        player.open(c, queue: items)
                    }
                    .channelActions(c, store: store) { path.append(c) }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search channels"))
        .refreshable { await store.refresh() }
    }
}

enum ChannelGroup: Hashable {
    case all
    case named(String)

    var name: String? {
        if case .named(let n) = self { return n }
        return nil
    }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .named(let n): return n
        }
    }
}

struct ChannelRow: View {
    let channel: Channel
    var onGuide: (() -> Void)?
    let onPlay: () -> Void
    @EnvironmentObject private var store: TVStore

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    rowContent(now: ctx.date)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onGuide {
                Button(action: onGuide) {
                    Image(systemName: "calendar")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("TV Guide"))
            }
        }
        .padding(.vertical, 2)
    }

    private func rowContent(now: Date) -> some View {
        let (cur, next) = store.epg.nowNext(for: channel, at: now)
        return HStack(spacing: 12) {
            LogoView(channel: channel, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: channel.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if store.isFavorite(channel) {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.orange)
                            .accessibilityLabel(Text("Favorite"))
                    }
                    if channel.hasArchive {
                        Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Archive"))
                    }
                }
                if let cur {
                    Text(verbatim: cur.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressLine(value: cur.progress(at: now))
                        .frame(maxWidth: 220)
                        .padding(.top, 2)
                } else if let next {
                    Text("Next: \(next.start.hm) \(next.title)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
