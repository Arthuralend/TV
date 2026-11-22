import Foundation
import SwiftUI

enum EPGStatus: Equatable {
    case idle, loading, failed
}

@MainActor
final class TVStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var selectedPlaylistID: UUID?
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var groups: [String] = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var recents: [String] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var epgVersion = 0
    @Published private(set) var epgStatus: EPGStatus = .idle

    let epg = EPGService()

    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    var selectedPlaylist: Playlist? { playlists.first { $0.id == selectedPlaylistID } }
    var epgUpdated: Date? { epg.savedAt }

    init() {
        playlists = load([Playlist].self, "playlists.json") ?? []
        favorites = load(Set<String>.self, "favorites.json") ?? []
        recents = load([String].self, "recents.json") ?? []
        let saved = UserDefaults.standard.string(forKey: "selectedPlaylist").flatMap(UUID.init)
        selectedPlaylistID = playlists.contains { $0.id == saved } ? saved : playlists.first?.id
        if let p = selectedPlaylist { Task { await open(p, forceRefresh: false) } }
    }

    // MARK: persistence

    private func load<T: Decodable>(_ t: T.Type, _ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private func save<T: Encodable>(_ v: T, _ name: String) {
        guard let d = try? JSONEncoder().encode(v) else { return }
        try? d.write(to: dir.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func savePlaylists() { save(playlists, "playlists.json") }

    // MARK: playlists

    func add(_ p: Playlist) {
        playlists.append(p)
        savePlaylists()
        select(p.id)
    }

    func update(_ p: Playlist) {
        guard let i = playlists.firstIndex(where: { $0.id == p.id }) else { return }
        playlists[i] = p
        savePlaylists()
        if p.id == selectedPlaylistID {
            epgLoadedFor = nil
            Task { await open(p, forceRefresh: true) }
        }
    }

    func remove(_ p: Playlist) {
        playlists.removeAll { $0.id == p.id }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("channels-\(p.id).json"))
        if p.kind == .file { try? FileManager.default.removeItem(at: PlaylistFiles.url(for: p.source)) }
        savePlaylists()
        if selectedPlaylistID == p.id { select(playlists.first?.id) }
    }

    func select(_ id: UUID?) {
        selectedPlaylistID = id
        UserDefaults.standard.set(id?.uuidString, forKey: "selectedPlaylist")
        channels = []
        groups = []
        epg.clear()
        epgVersion += 1
        epgLoadedFor = nil
        if let p = selectedPlaylist { Task { await open(p, forceRefresh: false) } }
    }

    func refresh() async {
        guard let p = selectedPlaylist else { return }
        epgLoadedFor = nil
        await open(p, forceRefresh: true)
    }

    /// Called when the app comes to the foreground: refreshes what is out of date.
    func refreshIfStale() {
        guard let p = selectedPlaylist, !isLoading else { return }
        let stale = p.lastUpdated.map { Date().timeIntervalSince($0) > Double(p.autoRefreshHours) * 3600 } ?? true
        if stale && p.autoRefreshHours > 0 { Task { await open(p, forceRefresh: true) } }
        else if let saved = epg.savedAt, Date().timeIntervalSince(saved) > 8 * 3600 {
            epgLoadedFor = nil
            Task { await loadEPG(p, nil) }
        }
    }

    /// A playlist file opened from Files / Share sheet.
    func importFile(_ url: URL) {
        do {
            let name = try PlaylistFiles.store(url)
            let title = url.deletingPathExtension().lastPathComponent
            add(Playlist(name: title.isEmpty ? String(localized: "Playlist") : title, kind: .file, source: name))
        } catch {
            errorMessage = String(localized: "Could not open the file: \(error.localizedDescription)")
        }
    }

    func open(_ p: Playlist, forceRefresh: Bool) async {
        let cacheName = "channels-\(p.id).json"
        let stale = p.lastUpdated.map { Date().timeIntervalSince($0) > Double(max(p.autoRefreshHours, 1)) * 3600 } ?? true
        let useCache = !forceRefresh && (!stale || p.kind == .file || p.autoRefreshHours == 0)
        if useCache, let cached = load([Channel].self, cacheName), !cached.isEmpty {
            apply(cached)
            await loadEPG(p, UserDefaults.standard.string(forKey: "epg-\(p.id)"))
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let text = try await fetchText(p)
            var result = await Task.detached(priority: .userInitiated) { M3UParser.parse(text) }.value
            if p.kind == .xtream {
                // keep live TV only: the Xtream playlist also lists films and series
                result.channels.removeAll { $0.url.contains("/movie/") || $0.url.contains("/series/") }
            }
            guard !result.channels.isEmpty else {
                throw NSError(domain: "TV", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "No channels found in the playlist")])
            }
            guard selectedPlaylistID == p.id else { return }
            apply(result.channels)
            save(channels, cacheName)
            if let i = playlists.firstIndex(where: { $0.id == p.id }) {
                playlists[i].lastUpdated = Date()
                savePlaylists()
            }
            await loadEPG(p, result.epgURL)
        } catch {
            guard selectedPlaylistID == p.id else { return }
            if let cached = load([Channel].self, cacheName), !cached.isEmpty {
                apply(cached)
                await loadEPG(p, UserDefaults.standard.string(forKey: "epg-\(p.id)"))
            }
            errorMessage = String(localized: "Could not load the playlist: \(error.localizedDescription)")
        }
    }

    private func fetchText(_ p: Playlist) async throws -> String {
        guard let url = p.playlistURL else { throw URLError(.badURL) }
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue(p.userAgent?.isEmpty == false ? p.userAgent! : "VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent")
            let (d, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                throw NSError(domain: "TV", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(h.statusCode)"])
            }
            data = d
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: TV guide

    private var epgLoadedFor: String?

    func guideSources(for p: Playlist, fromPlaylist: String?) -> [String] {
        var list: [String] = []
        if let e = p.epgURL, !e.isEmpty { list.append(e) }
        if let e = p.providerGuideURL { list.append(e) }
        if let e = fromPlaylist, !e.isEmpty {
            list += e.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if UserDefaults.standard.bool(forKey: Prefs.useDefaultEPG) { list += EPGService.defaultSources }
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private func loadEPG(_ p: Playlist, _ fromPlaylist: String?) async {
        if let fromPlaylist { UserDefaults.standard.set(fromPlaylist, forKey: "epg-\(p.id)") }
        let sources = guideSources(for: p, fromPlaylist: fromPlaylist)
        let key = sources.joined(separator: "|") + "#\(p.id)#\(channels.count)"
        guard epgLoadedFor != key else { return }
        epgLoadedFor = key
        // 1) show the saved guide immediately
        let savedAt = await epg.restore(playlist: p.id)
        epgVersion += 1
        // 2) refresh in the background when it is older than 8 hours (or missing)
        if let savedAt, Date().timeIntervalSince(savedAt) < 8 * 3600 { return }
        guard !sources.isEmpty else { return }
        epgStatus = .loading
        let list = channels, ua = p.userAgent, id = p.id
        do {
            try await epg.refresh(from: sources, userAgent: ua, channels: list, playlist: id)
            guard selectedPlaylistID == id else { return }
            epgStatus = .idle
            epgVersion += 1
        } catch {
            epgStatus = .failed
            epgLoadedFor = nil
        }
    }

    func reloadGuide() {
        guard let p = selectedPlaylist else { return }
        epgLoadedFor = nil
        EPGService.clearCache()
        Task { await loadEPG(p, UserDefaults.standard.string(forKey: "epg-\(p.id)")) }
    }

    private func apply(_ list: [Channel]) {
        var seen = Set<String>()
        channels = list.filter { seen.insert($0.id).inserted }
        var order: [String] = []
        var known = Set<String>()
        for c in channels where known.insert(c.group).inserted { order.append(c.group) }
        groups = order
    }

    // MARK: lists

    func channels(in group: String?, search: String) -> [Channel] {
        var list = group.map { g in channels.filter { $0.group == g } } ?? channels
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        return list
    }

    var favoriteChannels: [Channel] { channels.filter { favorites.contains($0.id) } }

    var recentChannels: [Channel] {
        let map = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return recents.compactMap { map[$0] }
    }

    func channel(withId id: String) -> Channel? { channels.first { $0.id == id } }

    func isFavorite(_ c: Channel) -> Bool { favorites.contains(c.id) }

    func toggleFavorite(_ c: Channel) {
        if favorites.contains(c.id) { favorites.remove(c.id) } else { favorites.insert(c.id) }
        save(favorites, "favorites.json")
    }

    func markPlayed(_ c: Channel) {
        recents.removeAll { $0 == c.id }
        recents.insert(c.id, at: 0)
        if recents.count > 30 { recents.removeLast(recents.count - 30) }
        save(recents, "recents.json")
    }

    func clearRecents() {
        recents = []
        save(recents, "recents.json")
    }
}
