import Foundation

struct Channel: Identifiable, Hashable, Codable {
    var id: String { url + "|" + name }
    var name: String
    var url: String
    var logo: String?
    var group: String
    var tvgId: String?
    var tvgName: String?
    var userAgent: String?
    var catchup: String?
    var catchupSource: String?
    var catchupDays: Int?

    var hasArchive: Bool {
        guard let c = catchup?.lowercased(), !c.isEmpty, c != "0", c != "false" else { return false }
        return true
    }
}

enum PlaylistKind: String, Codable, CaseIterable, Identifiable {
    case url, file, xtream
    var id: String { rawValue }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: PlaylistKind
    /// M3U link (`url`), stored file name (`file`) or server address (`xtream`)
    var source: String
    var username: String?
    var password: String?
    /// XMLTV guide chosen by the user (overrides the one named in the playlist)
    var epgURL: String?
    var userAgent: String?
    var lastUpdated: Date?
    var autoRefreshHours: Int

    init(name: String, kind: PlaylistKind, source: String, username: String? = nil, password: String? = nil,
         epgURL: String? = nil, userAgent: String? = nil, autoRefreshHours: Int = 24) {
        self.name = name
        self.kind = kind
        self.source = source
        self.username = username
        self.password = password
        self.epgURL = epgURL
        self.userAgent = userAgent
        self.autoRefreshHours = autoRefreshHours
    }

    var playlistURL: URL? {
        switch kind {
        case .url: return URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines))
        case .file: return PlaylistFiles.url(for: source)
        case .xtream: return Xtream.url(server: source, path: "get.php", username: username ?? "", password: password ?? "",
                                        extra: [URLQueryItem(name: "type", value: "m3u_plus"), URLQueryItem(name: "output", value: "m3u8")])
        }
    }

    /// Guide that comes with the account (Xtream Codes)
    var providerGuideURL: String? {
        guard kind == .xtream else { return nil }
        return Xtream.url(server: source, path: "xmltv.php", username: username ?? "", password: password ?? "", extra: [])?.absoluteString
    }
}

enum Xtream {
    static func normalizedServer(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "http://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    static func url(server: String, path: String, username: String, password: String, extra: [URLQueryItem]) -> URL? {
        guard var c = URLComponents(string: normalizedServer(server) + "/" + path) else { return nil }
        c.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)] + extra
        return c.url
    }
}

/// Playlist files imported from the Files app live inside the app container.
enum PlaylistFiles {
    static var directory: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    /// Copies a picked or opened file into the container and returns its stored name.
    static func store(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let name = UUID().uuidString + ".m3u"
        try data.write(to: Self.url(for: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }
}

struct Programme: Codable, Hashable, Identifiable {
    var start: Date
    var stop: Date
    var title: String
    var desc: String?

    var id: Double { start.timeIntervalSince1970 }

    func progress(at now: Date = Date()) -> Double {
        let total = stop.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    func isLive(at now: Date = Date()) -> Bool { start <= now && stop > now }
}

enum AppLinks {
    static let privacy = URL(string: "https://arthuralend.github.io/TV/privacy.html")!
    static let terms = URL(string: "https://arthuralend.github.io/TV/terms.html")!
    static let support = URL(string: "https://arthuralend.github.io/TV/")!
}

enum Prefs {
    static let engine = "playerEngine"
    static let networkCaching = "networkCaching"
    static let useLogoDB = "useLogoDB"
    static let useDefaultEPG = "useDefaultEPG"

    static func register() {
        UserDefaults.standard.register(defaults: [
            engine: PlayerEngine.auto.rawValue,
            networkCaching: 1500,
            useLogoDB: true,
            useDefaultEPG: true,
        ])
    }
}

extension Date {
    var hm: String { formatted(date: .omitted, time: .shortened) }
}
