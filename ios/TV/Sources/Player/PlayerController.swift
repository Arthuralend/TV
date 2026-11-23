import AVFoundation
import MediaPlayer
import MobileVLCKit
import SwiftUI
import UIKit

struct AudioTrack: Identifiable, Hashable {
    let id: Int
    let name: String
}

/// VLC is the only playback engine.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    @Published var isPresented = false
    @Published private(set) var channel: Channel?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var failure: String?
    @Published private(set) var archiveStart: Date?
    @Published private(set) var audioTracks: [AudioTrack] = []
    @Published private(set) var selectedAudioTrack: Int?
    @Published var fill = false { didSet { applyFill() } }
    @Published var toast: String?
    @Published var showChannelList = false
    @Published var showGroupList = false
    /// Group the channel list over the video is showing (nil = the list the channel was opened from).
    @Published private(set) var queueTitle: String?
    @Published private(set) var queue: [Channel] = []

    weak var store: TVStore?

    /// Hosts the video; every stream gets its own surface inside it.
    let videoView = UIView()
    /// A fresh VLC player per stream: the old one is stopped off the main thread
    /// (VLC's stop waits for its network threads and would freeze the screen).
    private var vlc: VLCMediaPlayer?
    private var surface: UIView?
    private static let stopQueue = DispatchQueue(label: "tv.vlc.stop", qos: .userInitiated)
    /// Same User-Agent the playlist is downloaded with: many providers bind access to it.
    static let defaultUserAgent = "VLC/3.0.20 LibVLC/3.0.20"
    private var attempt = 0
    private var pausedForBackground = false

    override init() {
        super.init()
        videoView.backgroundColor = .black
        videoView.clipsToBounds = true
        setupRemoteCommands()
    }

    // MARK: public API

    var isArchive: Bool { archiveStart != nil }

    /// Opens a channel live. `queue` is the list it was picked from (used by next / previous).
    func open(_ c: Channel, queue: [Channel]) {
        self.queue = queue.isEmpty ? [c] : queue
        queueTitle = nil
        archiveStart = nil
        start(c, urlString: c.url)
        isPresented = true
    }

    /// Plays a past programme from the provider's archive (catch-up).
    func openArchive(_ c: Channel, from date: Date, queue: [Channel]? = nil) {
        guard let url = Catchup.url(for: c, start: date) else {
            flash(String(localized: "Archive is not available for this channel"))
            return
        }
        if let queue { self.queue = queue }
        if self.queue.isEmpty { self.queue = [c] }
        archiveStart = date
        start(c, urlString: url)
        isPresented = true
    }

    func goLive() {
        guard let c = channel else { return }
        archiveStart = nil
        start(c, urlString: c.url)
    }

    func retry() {
        guard let c = channel else { return }
        if let a = archiveStart, let url = Catchup.url(for: c, start: a) {
            start(c, urlString: url)
        } else {
            start(c, urlString: c.url)
        }
    }

    /// Picked in the group list over the video: shows that group's channels.
    func showGroup(_ name: String?) {
        guard let store else { return }
        let list = store.channels(in: name, search: "")
        guard !list.isEmpty else { return }
        queue = list
        queueTitle = name ?? String(localized: "All Channels")
        showGroupList = false
        showChannelList = true
    }

    func showFavorites(_ list: [Channel]) {
        queue = list
        queueTitle = String(localized: "Favorites")
        showGroupList = false
        showChannelList = true
    }

    /// Switches to another channel live (from the channel list over the video).
    func play(_ c: Channel) {
        archiveStart = nil
        start(c, urlString: c.url)
    }

    func step(_ delta: Int) {
        guard let c = channel, !queue.isEmpty else { return }
        let i = queue.firstIndex { $0.id == c.id } ?? 0
        let next = queue[(i + delta + queue.count) % queue.count]
        archiveStart = nil
        start(next, urlString: next.url)
    }

    func togglePause() {
        guard let v = vlc else { retry(); return }
        if v.isPlaying { v.pause() } else { v.play() }
    }

    /// Moves through the archive (or into it from live, when the channel has one).
    func jump(_ seconds: Double) {
        guard let c = channel else { return }
        if isArchive {
            let target = positionDate.addingTimeInterval(seconds)
            if target > Date().addingTimeInterval(-30) { goLive(); return }
            reopenArchive(c, from: target)
        } else if seconds < 0, c.hasArchive {
            let limit = Date().addingTimeInterval(-Double(c.catchupDays ?? 7) * 86400)
            reopenArchive(c, from: max(Date().addingTimeInterval(seconds), limit))
        } else {
            flash(String(localized: "Rewind is not available for this channel"))
        }
    }

    func selectAudioTrack(_ id: Int) {
        vlc?.currentAudioTrackIndex = Int32(id)
        selectedAudioTrack = id
    }

    func close() {
        stop()
        channel = nil
        archiveStart = nil
        failure = nil
        showChannelList = false
        showGroupList = false
        isPresented = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        DispatchQueue.global(qos: .utility).async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Wall-clock moment currently on screen.
    var positionDate: Date {
        guard let a = archiveStart else { return Date() }
        let seconds = Double(vlc?.time.intValue ?? 0) / 1000
        return a.addingTimeInterval(max(0, seconds))
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if let v = vlc, v.isPlaying {
                v.pause()               // VLC must not draw video in the background
                pausedForBackground = true
            }
        case .active:
            if pausedForBackground { vlc?.play() }
            pausedForBackground = false
        default:
            break
        }
    }

    func flash(_ text: String) {
        toast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: playback

    private var userAgent: String {
        let ua = channel?.userAgent ?? store?.selectedPlaylist?.userAgent
        return ua?.isEmpty == false ? ua! : Self.defaultUserAgent
    }

    private func reopenArchive(_ c: Channel, from date: Date) {
        guard let url = Catchup.url(for: c, start: date) else { return }
        archiveStart = date
        start(c, urlString: url)
    }

    private func start(_ c: Channel, urlString: String) {
        stop()
        channel = c
        store?.markPlayed(c)
        failure = nil
        isBuffering = true
        isPlaying = false
        audioTracks = []
        selectedAudioTrack = nil
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed)
                ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:)) else {
            failure = String(localized: "Invalid stream address")
            isBuffering = false
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)

        attempt += 1
        let token = attempt
        let view = UIView(frame: videoView.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.backgroundColor = .black
        videoView.addSubview(view)
        let player = VLCMediaPlayer()
        player.drawable = view
        player.delegate = self
        let media = VLCMedia(url: url)
        let caching = max(300, UserDefaults.standard.integer(forKey: Prefs.networkCaching))
        media.addOption(":network-caching=\(caching)")
        media.addOption(":live-caching=\(caching)")
        media.addOption(":http-reconnect")
        media.addOption(":http-user-agent=\(userAgent)")
        player.media = media
        vlc = player
        surface = view
        applyFill()
        player.play()
        updateNowPlaying()

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.attempt == token, !self.isPlaying, self.failure == nil else { return }
            self.failure = String(localized: "The stream did not start in time")
            self.isBuffering = false
        }
    }

    private func stop() {
        attempt += 1
        isPlaying = false
        guard let old = vlc else { return }
        let oldSurface = surface
        vlc = nil
        surface = nil
        old.delegate = nil
        oldSurface?.removeFromSuperview()
        Self.stopQueue.async {
            old.stop()
            withExtendedLifetime(oldSurface) {}
        }
    }

    fileprivate func stateChanged() {
        guard let vlc else { return }
        switch vlc.state {
        case .opening:
            isBuffering = true
        case .buffering:
            isBuffering = !vlc.isPlaying
        case .playing:
            isBuffering = false
            isPlaying = true
            failure = nil
            refreshTracks()
        case .paused:
            isPlaying = false
        case .stopped, .ended:
            isPlaying = false
            isBuffering = false
        case .error:
            isPlaying = false
            isBuffering = false
            failure = String(localized: "Could not play this stream")
        default:
            break
        }
    }

    fileprivate func timeChanged() {
        guard let vlc else { return }
        if isBuffering { isBuffering = false }
        if !isPlaying { isPlaying = vlc.isPlaying }
        if audioTracks.isEmpty { refreshTracks() }
    }

    private func refreshTracks() {
        guard let vlc else { return }
        let names = (vlc.audioTrackNames as? [String]) ?? []
        let indexes = (vlc.audioTrackIndexes as? [NSNumber]) ?? []
        audioTracks = zip(indexes, names).map { AudioTrack(id: $0.intValue, name: $1) }.filter { $0.id >= 0 }
        selectedAudioTrack = Int(vlc.currentAudioTrackIndex)
    }

    private func applyFill() {
        guard let vlc else { return }
        let size = videoView.bounds.size
        if fill, size.width > 0, size.height > 0 {
            vlc.videoCropGeometry = strdup("\(Int(size.width)):\(Int(size.height))")
        } else {
            vlc.videoCropGeometry = nil
        }
    }

    // MARK: lock screen / Control Center

    private func updateNowPlaying() {
        guard let c = channel else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: c.name,
            MPNowPlayingInfoPropertyIsLiveStream: !isArchive,
        ]
        if let p = store?.epg.programme(for: c, at: positionDate) { info[MPMediaItemPropertyArtist] = p.title }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePause() }
            return .success
        }
        rc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.vlc?.play() }
            return .success
        }
        rc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.vlc?.pause() }
            return .success
        }
        rc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.step(1) }
            return .success
        }
        rc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.step(-1) }
            return .success
        }
    }
}

extension PlayerController: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in self.stateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in self.timeChanged() }
    }
}
