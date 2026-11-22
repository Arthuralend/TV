import CryptoKit
import Foundation

/// TV guide (XMLTV, .xml or .xml.gz). Channels are matched by tvg-id or by normalized name,
/// the same normalization as the logo index ("Первый канал HD" == "Первый канал").
@MainActor
final class EPGService {
    /// Used when the playlist does not name a guide (the iLook TV guide first, then a spare source).
    static let defaultSources = [
        "http://epg.it999.ru/epg2.xml.gz",
        "https://iptvx.one/epg/epg.xml.gz",
    ]

    /// channel id -> programmes sorted by start (only the current playlist's channels)
    private(set) var byChannel: [String: [Programme]] = [:]
    private(set) var iconByChannel: [String: String] = [:]
    private(set) var savedAt: Date?

    private struct Compact: Codable {
        var savedAt: Date
        var byChannel: [String: [Programme]]
        var icons: [String: String]
    }

    private func compactURL(_ playlist: UUID) -> URL {
        EPGLoader.cacheDir.appendingPathComponent("compact-\(playlist.uuidString).json")
    }

    /// Instant start: restores the guide saved after the last download.
    @discardableResult
    func restore(playlist: UUID) async -> Date? {
        let url = compactURL(playlist)
        let c = await Task.detached(priority: .userInitiated) { () -> Compact? in
            guard let d = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Compact.self, from: d)
        }.value
        guard let c else { clear(); return nil }
        byChannel = c.byChannel
        iconByChannel = c.icons
        savedAt = c.savedAt
        return c.savedAt
    }

    func clear() {
        byChannel = [:]
        iconByChannel = [:]
        savedAt = nil
    }

    /// Downloads and parses the guide, keeps only this playlist's channels and saves them compactly.
    func refresh(from sources: [String], userAgent: String?, channels: [Channel], playlist: UUID) async throws {
        let wanted = EPGWanted(channels)
        let data = try await Task.detached(priority: .utility) {
            try await EPGLoader.load(sources: sources, userAgent: userAgent, wanted: wanted)
        }.value
        let from = Date().addingTimeInterval(-7 * 86400), to = Date().addingTimeInterval(3 * 86400)
        var map: [String: [Programme]] = [:]
        var icons: [String: String] = [:]
        for c in channels {
            let list = data.schedule(for: c).filter { $0.stop > from && $0.start < to }
            if !list.isEmpty { map[c.id] = list }
            if let ic = data.icon(for: c) { icons[c.id] = ic }
        }
        byChannel = map
        iconByChannel = icons
        savedAt = Date()
        let compact = Compact(savedAt: Date(), byChannel: map, icons: icons)
        let url = compactURL(playlist)
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(compact) { try? d.write(to: url, options: .atomic) }
        }
    }

    func schedule(for c: Channel) -> [Programme] { byChannel[c.id] ?? [] }

    func icon(for c: Channel) -> String? { iconByChannel[c.id] }

    func programme(for c: Channel, at date: Date) -> Programme? {
        schedule(for: c).first { $0.start <= date && $0.stop > date }
    }

    func nowNext(for c: Channel, at now: Date = Date()) -> (Programme?, Programme?) {
        let list = schedule(for: c)
        guard let i = list.firstIndex(where: { $0.isLive(at: now) }) else {
            return (nil, list.first { $0.start > now })
        }
        return (list[i], i + 1 < list.count ? list[i + 1] : nil)
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: EPGLoader.cacheDir)
    }
}

/// Which guide channels to keep while parsing (a full guide has thousands of channels).
struct EPGWanted: Sendable {
    let ids: Set<String>
    let nameKeys: Set<String>

    init(_ channels: [Channel]) {
        var ids = Set<String>(), keys = Set<String>()
        for c in channels {
            if let t = c.tvgId?.lowercased(), !t.isEmpty { ids.insert(t) }
            for n in [c.tvgName, c.name].compactMap({ $0 }) where !n.isEmpty {
                keys.formUnion(LogoDatabase.keys(n))
            }
        }
        self.ids = ids
        self.nameKeys = keys
    }
}

struct EPGData: Sendable {
    var programmes: [String: [Programme]] = [:]
    var idByLower: [String: String] = [:]
    var idByName: [String: String] = [:]
    var iconById: [String: String] = [:]

    private func guideId(for c: Channel) -> String? {
        if let t = c.tvgId?.lowercased(), !t.isEmpty, let id = idByLower[t], programmes[id] != nil { return id }
        for n in [c.tvgName, c.name].compactMap({ $0 }) where !n.isEmpty {
            for k in LogoDatabase.keys(n) {
                if let id = idByName[k], programmes[id] != nil { return id }
            }
        }
        return nil
    }

    func schedule(for c: Channel) -> [Programme] { guideId(for: c).flatMap { programmes[$0] } ?? [] }

    func icon(for c: Channel) -> String? {
        if let id = guideId(for: c), let ic = iconById[id] { return ic }
        for n in [c.tvgName, c.name].compactMap({ $0 }) where !n.isEmpty {
            for k in LogoDatabase.keys(n) { if let id = idByName[k], let ic = iconById[id] { return ic } }
        }
        return nil
    }
}

enum EPGLoader {
    static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epg", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Loads the first source that works.
    static func load(sources: [String], userAgent: String?, wanted: EPGWanted) async throws -> EPGData {
        var lastError: Error = URLError(.badURL)
        for s in sources {
            do {
                let file = try await xmlFile(for: s, userAgent: userAgent)
                let data = XMLTVParser(wanted: wanted).parse(file)
                if !data.programmes.isEmpty { return data }
                lastError = URLError(.cannotParseResponse)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Downloads the guide (or reuses a copy younger than 8 hours) and returns the unpacked XML file.
    private static func xmlFile(for source: String, userAgent: String?) async throws -> URL {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw URLError(.badURL) }
        let name = SHA256.hash(data: Data(source.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let xml = cacheDir.appendingPathComponent(name + ".xml")
        let fm = FileManager.default
        if let m = (try? fm.attributesOfItem(atPath: xml.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(m) < 8 * 3600 {
            return xml
        }
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.setValue(userAgent?.isEmpty == false ? userAgent! : "Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            try? fm.removeItem(at: tmp)
            throw URLError(.badServerResponse)
        }
        let download = cacheDir.appendingPathComponent(name + ".download")
        try? fm.removeItem(at: download)
        try fm.moveItem(at: tmp, to: download)
        defer { try? fm.removeItem(at: download) }
        try? fm.removeItem(at: xml)
        if Gzip.isGzip(file: download) {
            try Gzip.decompress(file: download, to: xml)
        } else {
            try fm.moveItem(at: download, to: xml)
        }
        return xml
    }
}

private final class XMLTVParser: NSObject, XMLParserDelegate {
    private let wanted: EPGWanted
    private var data = EPGData()
    private var channelNames: [String: [String]] = [:]
    private var channelIcon: [String: String] = [:]
    private var decided: [String: Bool] = [:]
    private var currentChannelId: String?
    private var progChannel: String?
    private var progStart: Date?
    private var progStop: Date?
    private var title = ""
    private var desc = ""
    private var text = ""
    private var capture = false
    private let windowStart = Date().addingTimeInterval(-7 * 86400)   // archive up to a week back
    private let windowEnd = Date().addingTimeInterval(3 * 86400)

    init(wanted: EPGWanted) { self.wanted = wanted }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss Z"
        return f
    }()
    private static let formatterNoTZ: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return formatter.date(from: s) ?? formatterNoTZ.date(from: String(s.prefix(14)))
    }

    func parse(_ file: URL) -> EPGData {
        guard let stream = InputStream(url: file) else { return data }
        let p = XMLParser(stream: stream)
        p.delegate = self
        p.parse()
        for k in data.programmes.keys { data.programmes[k]?.sort { $0.start < $1.start } }
        for (id, names) in channelNames where isWanted(id) {
            data.idByLower[id.lowercased()] = id
            for n in names {
                for k in LogoDatabase.keys(n) where data.idByName[k] == nil { data.idByName[k] = id }
            }
            if let ic = channelIcon[id] { data.iconById[id] = ic }
        }
        for id in data.programmes.keys where data.idByLower[id.lowercased()] == nil { data.idByLower[id.lowercased()] = id }
        return data
    }

    private func isWanted(_ id: String) -> Bool {
        if let d = decided[id] { return d }
        var ok = wanted.ids.contains(id.lowercased())
        if !ok, let names = channelNames[id] {
            ok = names.contains { n in LogoDatabase.keys(n).contains { wanted.nameKeys.contains($0) } }
        }
        decided[id] = ok
        return ok
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch el {
        case "channel":
            currentChannelId = a["id"]
        case "display-name":
            capture = currentChannelId != nil; text = ""
        case "icon":
            if let id = currentChannelId, let src = a["src"], !src.isEmpty, channelIcon[id] == nil { channelIcon[id] = src }
        case "programme":
            progChannel = nil
            if let ch = a["channel"], isWanted(ch),
               let s = Self.date(a["start"]), let e = Self.date(a["stop"]), e > windowStart, s < windowEnd {
                progChannel = ch; progStart = s; progStop = e
                title = ""; desc = ""
            }
        case "title", "desc":
            capture = progChannel != nil; text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        switch el {
        case "display-name":
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = currentChannelId, !t.isEmpty { channelNames[id, default: []].append(t) }
        case "channel":
            currentChannelId = nil
        case "title":
            if progChannel != nil, title.isEmpty { title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "desc":
            if progChannel != nil, desc.isEmpty { desc = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "programme":
            if let ch = progChannel, let s = progStart, let e = progStop {
                data.programmes[ch, default: []].append(Programme(start: s, stop: e, title: title, desc: desc.isEmpty ? nil : desc))
            }
            progChannel = nil
        default:
            break
        }
        capture = false
        text = ""
    }
}
