import CryptoKit
import SwiftUI
import UIKit

/// Channel logos: memory + disk cache, downsampled to the size they are shown at.
actor LogoCache {
    static let shared = LogoCache()
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() { memory.countLimit = 600 }

    private func key(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func image(for urlString: String) async -> UIImage? {
        if let img = memory.object(forKey: urlString as NSString) { return img }
        let file = dir.appendingPathComponent(key(urlString))
        if let d = try? Data(contentsOf: file), let img = UIImage(data: d) {
            memory.setObject(img, forKey: urlString as NSString)
            return img
        }
        if let t = inFlight[urlString] { return await t.value }
        let t = Task<UIImage?, Never> {
            guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let full = UIImage(data: data) else { return nil }
            let img = Self.downsample(full)
            if let png = img.pngData() { try? png.write(to: file) }
            return img
        }
        inFlight[urlString] = t
        let img = await t.value
        inFlight[urlString] = nil
        if let img { memory.setObject(img, forKey: urlString as NSString) }
        return img
    }

    private static func downsample(_ img: UIImage) -> UIImage {
        let maxSide: CGFloat = 160
        let s = img.size
        guard s.width > maxSide || s.height > maxSide else { return img }
        let scale = maxSide / max(s.width, s.height)
        let target = CGSize(width: s.width * scale, height: s.height * scale)
        return img.preparingThumbnail(of: target) ?? img
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

struct LogoView: View {
    let channel: Channel
    var size: CGFloat = 44
    @EnvironmentObject private var store: TVStore
    @AppStorage(Prefs.useLogoDB) private var useLogoDB = true
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(image == nil ? AnyShapeStyle(placeholder) : AnyShapeStyle(Theme.card))
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .padding(size * 0.1)
            } else {
                Text(initials).font(.system(size: size * 0.34, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: channel.id + "\(useLogoDB)\(store.epgVersion)") {
            if let own = channel.logo, !own.isEmpty, let img = await LogoCache.shared.image(for: own) { image = img; return }
            if let ic = store.epg.icon(for: channel), let img = await LogoCache.shared.image(for: ic) { image = img; return }
            if useLogoDB,
               let db = await LogoDatabase.shared.logoURL(name: channel.name, tvgId: channel.tvgId, tvgName: channel.tvgName),
               let img = await LogoCache.shared.image(for: db) { image = img; return }
        }
    }

    private var initials: String {
        let words = channel.name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var placeholder: LinearGradient {
        let palette: [Color] = [Theme.orange, Theme.orangeDeep, Color(red: 0.36, green: 0.62, blue: 0.75), Color(red: 0.42, green: 0.43, blue: 0.46)]
        let h = channel.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        let c = palette[h % palette.count]
        return LinearGradient(colors: [c.opacity(0.9), c.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
