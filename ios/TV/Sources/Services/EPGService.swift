import CryptoKit
import Darwin
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
    func refresh(from sources: [String], userAgent: String?, channels: [Channel], playlist: UUID,
                 stage: @escaping @Sendable (EPGStatus) -> Void) async throws {
        // everything heavy (download, scan, matching thousands of channels) stays off the main thread
        let task = Task.detached(priority: .utility) { () -> ([String: [Programme]], [String: String]) in
            let wanted = EPGWanted(channels)
            let data = try await EPGLoader.load(sources: sources, userAgent: userAgent, wanted: wanted, stage: stage)
            let from = Date().addingTimeInterval(-7 * 86400), to = Date().addingTimeInterval(3 * 86400)
            var map: [String: [Programme]] = [:]
            var icons: [String: String] = [:]
            for c in channels {
                let list = data.schedule(for: c).filter { $0.stop > from && $0.start < to }
                if !list.isEmpty { map[c.id] = list }
                if let ic = data.icon(for: c) { icons[c.id] = ic }
            }
            return (map, icons)
        }
        running = task
        defer { running = nil }
        let (map, icons) = try await task.value
        try Task.checkCancellation()
        guard !task.isCancelled else { throw CancellationError() }
        byChannel = map
        iconByChannel = icons
        savedAt = Date()
        let compact = Compact(savedAt: Date(), byChannel: map, icons: icons)
        let url = compactURL(playlist)
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(compact) { try? d.write(to: url, options: .atomic) }
        }
    }

    private var running: Task<([String: [Programme]], [String: String]), Error>?

    /// Stops a download / scan in progress (the TV guide was turned off).
    func cancel() { running?.cancel() }

    func schedule(for c: Channel) -> [Programme] { byChannel[c.id] ?? [] }

    func icon(for c: Channel) -> String? { iconByChannel[c.id] }

    /// Index of the first programme that ends after `date` (binary search: lists are sorted).
    private static func firstEnding(after date: Date, in list: [Programme]) -> Int {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].stop <= date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func programme(for c: Channel, at date: Date) -> Programme? {
        guard let list = byChannel[c.id] else { return nil }
        let i = Self.firstEnding(after: date, in: list)
        return i < list.count && list[i].start <= date ? list[i] : nil
    }

    func nowNext(for c: Channel, at now: Date = Date()) -> (Programme?, Programme?) {
        guard let list = byChannel[c.id] else { return (nil, nil) }
        let i = Self.firstEnding(after: now, in: list)
        guard i < list.count else { return (nil, nil) }
        if list[i].start <= now { return (list[i], i + 1 < list.count ? list[i + 1] : nil) }
        return (nil, list[i])
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
    static func load(sources: [String], userAgent: String?, wanted: EPGWanted,
                     stage: @escaping @Sendable (EPGStatus) -> Void) async throws -> EPGData {
        var lastError: Error = URLError(.badURL)
        for s in sources {
            try Task.checkCancellation()
            do {
                stage(.downloading)
                let file = try await xmlFile(for: s, userAgent: userAgent)
                stage(.processing)
                let data = XMLTVScanner(wanted: wanted).scan(file)
                if !data.programmes.isEmpty { return data }
                lastError = URLError(.cannotParseResponse)
            } catch {
                if error is CancellationError { throw error }
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
        var req = URLRequest(url: url, timeoutInterval: 30)   // idle timeout: a dead server is skipped quickly
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

/// Fast XMLTV reader. Scans the memory-mapped file byte by byte and jumps over the programmes
/// of channels that are not in the playlist (most of a big guide), instead of running a full XML parser.
private struct XMLTVScanner {
    let wanted: EPGWanted

    func scan(_ file: URL) -> EPGData {
        guard let d = try? Data(contentsOf: file, options: .alwaysMapped), !d.isEmpty else { return EPGData() }
        return d.withUnsafeBytes { raw -> EPGData in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return EPGData() }
            var s = ByteScan(p: base, n: raw.count, wanted: wanted)
            s.run()
            return s.result()
        }
    }
}

private struct ByteScan {
    let p: UnsafePointer<UInt8>
    let n: Int
    let wanted: EPGWanted

    private var data = EPGData()
    private var channelNames: [String: [String]] = [:]
    private var channelIcon: [String: String] = [:]
    private var decided: [String: Bool] = [:]
    private var lastIdStart = 0, lastIdLen = 0, lastId = "", lastWanted = false
    private let windowStart = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
    private let windowEnd = Date().addingTimeInterval(3 * 86400).timeIntervalSince1970

    init(p: UnsafePointer<UInt8>, n: Int, wanted: EPGWanted) {
        self.p = p
        self.n = n
        self.wanted = wanted
    }

    private static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private static let channelTag = bytes("channel")
    private static let programmeTag = bytes("programme")
    private static let channelClose = bytes("</channel>")
    private static let programmeClose = bytes("</programme>")
    private static let displayOpen = bytes("<display-name")
    private static let displayClose = bytes("</display-name>")
    private static let iconOpen = bytes("<icon")
    private static let titleOpen = bytes("<title")
    private static let titleClose = bytes("</title>")
    private static let descOpen = bytes("<desc")
    private static let descClose = bytes("</desc>")
    private static let idAttr = bytes("id=")
    private static let channelAttr = bytes("channel=")
    private static let startAttr = bytes("start=")
    private static let stopAttr = bytes("stop=")
    private static let srcAttr = bytes("src=")
    private static let cdataOpen = bytes("<![CDATA[")

    // MARK: byte helpers

    private func indexOf(_ byte: UInt8, _ from: Int, _ end: Int) -> Int? {
        guard from < end, let q = memchr(p + from, Int32(byte), end - from) else { return nil }
        return UnsafePointer<UInt8>(q.assumingMemoryBound(to: UInt8.self)) - p
    }

    private func find(_ pat: [UInt8], _ from: Int, _ end: Int) -> Int? {
        let m = pat.count
        var i = from
        while i <= end - m {
            guard let j = indexOf(pat[0], i, end - m + 1) else { return nil }
            if memcmp(p + j, pat, m) == 0 { return j }
            i = j + 1
        }
        return nil
    }

    private func matches(_ pat: [UInt8], at i: Int) -> Bool {
        i + pat.count <= n && memcmp(p + i, pat, pat.count) == 0
    }

    private func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 }

    /// Value range of `name="…"` (or single quotes) inside a tag.
    private func attr(_ name: [UInt8], _ from: Int, _ end: Int) -> (Int, Int)? {
        var i = from
        while let a = find(name, i, end) {
            let q = a + name.count
            if a > from, isSpace(p[a - 1]), q < end, p[q] == 34 || p[q] == 39,
               let close = indexOf(p[q], q + 1, end) {
                return (q + 1, close)
            }
            i = a + 1
        }
        return nil
    }

    private func string(_ a: Int, _ b: Int) -> String {
        guard b > a else { return "" }
        var s = a, e = b
        if matches(Self.cdataOpen, at: s), e - s >= 12, p[e - 1] == 62, p[e - 2] == 93, p[e - 3] == 93 {
            s += Self.cdataOpen.count
            e -= 3
        }
        while s < e, isSpace(p[s]) { s += 1 }
        while e > s, isSpace(p[e - 1]) { e -= 1 }
        let str = String(decoding: UnsafeBufferPointer(start: p + s, count: e - s), as: UTF8.self)
        return str.contains("&") ? Self.decodeEntities(str) : str
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let ent = s[s.index(after: i)..<semi]
                var rep: String?
                switch ent {
                case "amp": rep = "&"
                case "lt": rep = "<"
                case "gt": rep = ">"
                case "quot": rep = "\""
                case "apos": rep = "'"
                case "nbsp": rep = "\u{00A0}"
                default:
                    var v: UInt32?
                    if ent.hasPrefix("#x") || ent.hasPrefix("#X") { v = UInt32(ent.dropFirst(2), radix: 16) }
                    else if ent.hasPrefix("#") { v = UInt32(ent.dropFirst()) }
                    if let v, let u = Unicode.Scalar(v) { rep = String(Character(u)) }
                }
                if let rep {
                    out += rep
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    /// "20261122183000 +0300" -> seconds since 1970 (no time zone = UTC).
    private func date(_ a: Int, _ b: Int) -> TimeInterval? {
        func num(_ i: Int, _ len: Int) -> Int? {
            guard i + len <= b else { return nil }
            var v = 0
            for k in i..<(i + len) {
                let c = Int(p[k]) - 48
                guard c >= 0 && c <= 9 else { return nil }
                v = v * 10 + c
            }
            return v
        }
        guard let y = num(a, 4), let mo = num(a + 4, 2), let d = num(a + 6, 2),
              let h = num(a + 8, 2), let mi = num(a + 10, 2) else { return nil }
        var i = a + 12
        var sec = 0
        if let s = num(i, 2) { sec = s; i += 2 }
        while i < b, isSpace(p[i]) { i += 1 }
        var offset = 0
        if i < b, p[i] == 43 || p[i] == 45, let oh = num(i + 1, 2), let om = num(i + 3, 2) {
            offset = (oh * 3600 + om * 60) * (p[i] == 45 ? -1 : 1)
        }
        let days = Self.daysFromCivil(y, mo, d)
        return TimeInterval(days * 86400 + h * 3600 + mi * 60 + sec - offset)
    }

    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    // MARK: scanning

    mutating func run() {
        var i = 0
        var steps = 0
        while i < n {
            steps += 1
            if steps & 0xFFF == 0, Task.isCancelled { return }
            guard let lt = indexOf(60, i, n) else { break }      // "<"
            let after = lt + 1
            if matches(Self.programmeTag, at: after), after + 9 < n, isSpace(p[after + 9]) {
                i = programme(at: lt)
            } else if matches(Self.channelTag, at: after), after + 7 < n, isSpace(p[after + 7]) || p[after + 7] == 62 {
                i = channel(at: lt)
            } else {
                i = after
            }
        }
    }

    private mutating func channel(at lt: Int) -> Int {
        guard let te = indexOf(62, lt, n) else { return n }
        let id = attr(Self.idAttr, lt, te).map { string($0.0, $0.1) } ?? ""
        if p[te - 1] == 47 { return te + 1 }                    // <channel …/>
        let end = find(Self.channelClose, te, n) ?? n
        var names: [String] = []
        var k = te + 1
        while let a = find(Self.displayOpen, k, end), let ate = indexOf(62, a, end) {
            let ce = find(Self.displayClose, ate, end) ?? end
            let name = string(ate + 1, ce)
            if !name.isEmpty { names.append(name) }
            k = ce + 1
        }
        if !id.isEmpty {
            channelNames[id, default: []] += names
            if channelIcon[id] == nil, let ic = find(Self.iconOpen, te, end), let ite = indexOf(62, ic, end),
               let src = attr(Self.srcAttr, ic, ite) {
                let u = string(src.0, src.1)
                if !u.isEmpty { channelIcon[id] = u }
            }
        }
        return min(n, end + Self.channelClose.count)
    }

    private mutating func programme(at lt: Int) -> Int {
        guard let te = indexOf(62, lt, n) else { return n }
        let selfClosing = p[te - 1] == 47
        let blockEnd = selfClosing ? te : (find(Self.programmeClose, te, n) ?? n)
        let next = selfClosing ? te + 1 : min(n, blockEnd + Self.programmeClose.count)
        guard !selfClosing, let ch = attr(Self.channelAttr, lt, te) else { return next }

        // programmes come grouped by channel: compare bytes before making a String
        let len = ch.1 - ch.0
        let id: String
        let ok: Bool
        if len == lastIdLen, len > 0, memcmp(p + ch.0, p + lastIdStart, len) == 0 {
            id = lastId
            ok = lastWanted
        } else {
            id = string(ch.0, ch.1)
            ok = isWanted(id)
            lastIdStart = ch.0; lastIdLen = len; lastId = id; lastWanted = ok
        }
        guard ok,
              let sr = attr(Self.startAttr, lt, te), let start = date(sr.0, sr.1),
              let er = attr(Self.stopAttr, lt, te), let stop = date(er.0, er.1),
              stop > windowStart, start < windowEnd else { return next }

        var title = ""
        if let t = find(Self.titleOpen, te, blockEnd), let tte = indexOf(62, t, blockEnd) {
            title = string(tte + 1, find(Self.titleClose, tte, blockEnd) ?? blockEnd)
        }
        var desc: String?
        if let t = find(Self.descOpen, te, blockEnd), let tte = indexOf(62, t, blockEnd) {
            let d = string(tte + 1, find(Self.descClose, tte, blockEnd) ?? blockEnd)
            if !d.isEmpty { desc = d }
        }
        data.programmes[id, default: []].append(Programme(start: Date(timeIntervalSince1970: start),
                                                          stop: Date(timeIntervalSince1970: stop),
                                                          title: title, desc: desc))
        return next
    }

    private mutating func isWanted(_ id: String) -> Bool {
        if let d = decided[id] { return d }
        var ok = wanted.ids.contains(id.lowercased())
        if !ok, let names = channelNames[id] {
            ok = names.contains { n in LogoDatabase.keys(n).contains { wanted.nameKeys.contains($0) } }
        }
        decided[id] = ok
        return ok
    }

    mutating func result() -> EPGData {
        for k in data.programmes.keys { data.programmes[k]?.sort { $0.start < $1.start } }
        for (id, names) in channelNames where isWanted(id) {
            data.idByLower[id.lowercased()] = id
            for name in names {
                for k in LogoDatabase.keys(name) where data.idByName[k] == nil { data.idByName[k] = id }
            }
            if let ic = channelIcon[id] { data.iconById[id] = ic }
        }
        for id in data.programmes.keys where data.idByLower[id.lowercased()] == nil { data.idByLower[id.lowercased()] = id }
        return data
    }
}
