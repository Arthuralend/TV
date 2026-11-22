import SwiftUI
import UIKit

/// Colors taken from the app icon: orange TV cabinet, pale-blue screen, graphite.
enum Theme {
    static let orange = Color(red: 0.949, green: 0.502, blue: 0.039)      // #F2800A
    static let orangeDeep = Color(red: 0.851, green: 0.384, blue: 0.000)  // #D96200
    static let screen = Color(red: 0.741, green: 0.910, blue: 0.973)      // #BDE8F8
    static let background = Color(red: 0.071, green: 0.075, blue: 0.082)  // #121315
    static let card = Color(red: 0.169, green: 0.173, blue: 0.180)        // #2B2C2E
    static let orangeGradient = LinearGradient(colors: [orange, orangeDeep], startPoint: .top, endPoint: .bottom)
}

/// Thin progress line of the programme on air.
struct ProgressLine: View {
    let value: Double
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Theme.orange).frame(width: max(height, g.size.width * value))
            }
        }
        .frame(height: height)
        .accessibilityValue(Text("\(Int(value * 100))%"))
    }
}

/// Horizontal row of selectable capsules (groups, time slots, days).
struct ChipBar<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        let selected = item == selection
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { selection = item }
                        } label: {
                            Text(title(item))
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(selected ? AnyShapeStyle(Theme.orangeGradient) : AnyShapeStyle(Theme.card)))
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .id(item)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }
}

/// Shown before the first playlist is added. States clearly that the app ships no content.
struct WelcomeView: View {
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150)
                    .padding(.top, 40)
                    .accessibilityHidden(true)
                Text("Welcome to TV")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("TV is a player for your own IPTV playlists with a TV guide. The app does not include any channels: add the M3U playlist or Xtream Codes account given to you by your TV provider.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 14) {
                    feature("list.bullet.rectangle", "M3U / M3U8 links, files and Xtream Codes")
                    feature("calendar", "TV guide (XMLTV) with what's on now and next")
                    feature("clock.arrow.circlepath", "Archive playback when your provider supports it")
                    feature("pip", "Picture in Picture and AirPlay")
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                Button {
                    showEditor = true
                } label: {
                    Label("Add Playlist", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showEditor) { PlaylistEditor(playlist: nil) }
    }

    private func feature(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.orange)
                .frame(width: 30)
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Small banner at the top of lists (loading, errors).
struct StatusBanner: View {
    @EnvironmentObject private var store: TVStore

    var body: some View {
        if store.isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading playlist…").font(.footnote)
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(Theme.card)
        } else if let error = store.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(error).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    store.errorMessage = nil
                } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold))
                }
                .accessibilityLabel(Text("Close"))
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(Theme.card)
        }
    }
}

/// Toolbar menu that switches between playlists.
struct PlaylistMenu: View {
    @EnvironmentObject private var store: TVStore
    @State private var showEditor = false

    var body: some View {
        Menu {
            if store.playlists.count > 1 {
                Picker(selection: Binding(get: { store.selectedPlaylistID }, set: { store.select($0) })) {
                    ForEach(store.playlists) { p in Text(verbatim: p.name).tag(Optional(p.id)) }
                } label: {
                    Text("Playlist")
                }
                Divider()
            }
            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh Playlist", systemImage: "arrow.clockwise")
            }
            Button {
                showEditor = true
            } label: {
                Label("Add Playlist", systemImage: "plus")
            }
        } label: {
            Image(systemName: "list.bullet.rectangle.portrait")
                .accessibilityLabel(Text("Playlists"))
        }
        .sheet(isPresented: $showEditor) { PlaylistEditor(playlist: nil) }
    }
}

extension View {
    /// Opens the TV guide of a channel from a context menu or swipe.
    func channelActions(_ c: Channel, store: TVStore, openGuide: @escaping () -> Void) -> some View {
        self
            .contextMenu {
                Button {
                    store.toggleFavorite(c)
                } label: {
                    if store.isFavorite(c) {
                        Label("Remove from Favorites", systemImage: "star.slash")
                    } else {
                        Label("Add to Favorites", systemImage: "star")
                    }
                }
                Button(action: openGuide) { Label("TV Guide", systemImage: "calendar") }
                Button {
                    UIPasteboard.general.string = c.url
                } label: {
                    Label("Copy Stream Link", systemImage: "doc.on.doc")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    store.toggleFavorite(c)
                } label: {
                    if store.isFavorite(c) {
                        Label("Remove", systemImage: "star.slash")
                    } else {
                        Label("Favorite", systemImage: "star")
                    }
                }
                .tint(Theme.orange)
            }
    }
}
