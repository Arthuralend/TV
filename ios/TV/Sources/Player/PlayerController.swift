import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
import UIKit

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct AudioTrack: Identifiable, Hashable {
    let id: Int
    let name: String
}

enum PlayerEngine: String, CaseIterable, Identifiable {
    case mpv, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mpv: return String(localized: "MPV (recommended)")
        case .system: return String(localized: "System (AVPlayer)")
        }
    }

    static var current: PlayerEngine {
        PlayerEngine(rawValue: UserDefaults.standard.string(forKey: Prefs.engine) ?? "") ?? .mpv
    }
}

/// Two engines behind one controller:
/// MPV (mpv + FFmpeg, default) — fastest and most tolerant of IPTV streams, no Picture in Picture;
/// the system player — HLS only, with Picture in Picture and AirPlay.
/// If the system player cannot open a stream, it falls back to MPV.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    enum Active { case none, system, mpv }

    @Published var isPresented = false
    @Published private(set) var channel: Channel?
    @Published private(set) var active: Active = .none
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var failure: String?
    @Published private(set) var archiveStart: Date?
    @Published private(set) var audioTracks: [AudioTrack] = []
    @Published private(set) var selectedAudioTrack: Int?
    @Published private(set) var pipPossible = false
    @Published private(set) var pipActive = false
    @Published var fill = false { didSet { applyFill() } }
    @Published var toast: String?
    @Published var showChannelList = false
    @Published var showGroupList = false
    /// Group the channel list over the video is showing (nil = the list the channel was opened from).
    @Published private(set) var queueTitle: String?

    weak var store: TVStore?
    @Published private(set) var queue: [Channel] = []

    let avPlayer = AVPlayer()
    let avView = PlayerLayerView()
    let mpv = MPVEngine()
    /// Same User-Agent the playlist was downloaded with: many providers bind access to it.
    static let defaultUserAgent = "VLC/3.0.20 LibVLC/3.0.20"
    private var pip: AVPictureInPictureController?
    private var pipObservers: [NSKeyValueObservation] = []
    private var playerObserver: NSKeyValueObservation?
    private var itemObservers: [NSKeyValueObservation] = []
    private var currentURL: URL?
    private var attempt = 0
    private var didFallback = false
    private var audioGroup: AVMediaSelectionGroup?

    override init() {
        super.init()
        avView.backgroundColor = .black
        avView.playerLayer.player = avPlayer
        avView.playerLayer.videoGravity = .resizeAspect
        avPlayer.allowsExternalPlayback = true
        mpv.onEvent = { [weak self] e in self?.mpvEvent(e) }

        if AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: avView.playerLayer) {
            pip.delegate = self
            pip.canStartPictureInPictureAutomaticallyFromInline = true
            self.pip = pip
            pipObservers = [
                pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] p, _ in
                    let v = p.isPictureInPicturePossible
                    Task { @MainActor in self?.pipPossible = v }
                },
                pip.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] p, _ in
                    let v = p.isPictureInPictureActive
                    Task { @MainActor in self?.pipActive = v }
                },
            ]
        }
        playerObserver = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let s = p.timeControlStatus
            Task { @MainActor in self?.timeControlChanged(s) }
        }
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

    func retry(engine forced: Active? = nil) {
        guard let c = channel else { return }
        if let a = archiveStart, let url = Catchup.url(for: c, start: a) {
            start(c, urlString: url, forced: forced)
        } else {
            start(c, urlString: c.url, forced: forced)
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
        switch active {
        case .system: if avPlayer.timeControlStatus == .paused { avPlayer.play() } else { avPlayer.pause() }
        case .mpv: mpv.setPaused(!mpv.isPaused)
        case .none: retry()
        }
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
        switch active {
        case .system:
            guard let g = audioGroup, id < g.options.count else { return }
            avPlayer.currentItem?.select(g.options[id], in: g)
        case .mpv:
            mpv.selectAudioTrack(id)
        case .none:
            return
        }
        selectedAudioTrack = id
    }

    func togglePiP() {
        guard active == .system, let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }

    func close() {
        if let pip, pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        stopEngines()
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
        return a.addingTimeInterval(max(0, currentSeconds))
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if active == .mpv {
                mpv.setVideoEnabled(false)        // sound keeps playing in the background
            } else if active == .system, !pipActive {
                avView.playerLayer.player = nil   // keeps the sound playing in the background
            }
        case .active:
            avView.playerLayer.player = avPlayer
            if active == .mpv { mpv.setVideoEnabled(true) }
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

    // MARK: engines

    private var userAgent: String {
        let ua = channel?.userAgent ?? store?.selectedPlaylist?.userAgent
        return ua?.isEmpty == false ? ua! : Self.defaultUserAgent
    }

    private var preference: PlayerEngine { PlayerEngine.current }

    private var currentSeconds: Double {
        switch active {
        case .system:
            let s = avPlayer.currentTime().seconds
            return s.isFinite ? s : 0
        case .mpv:
            return mpv.position
        case .none:
            return 0
        }
    }

    private func reopenArchive(_ c: Channel, from date: Date) {
        guard let url = Catchup.url(for: c, start: date) else { return }
        archiveStart = date
        start(c, urlString: url)
    }

    private static func prefersSystem(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        let path = url.path.lowercased()
        if s.contains(".m3u8") || s.contains("output=m3u8") || s.contains("output=hls") { return true }
        return ["mp4", "m4v", "mov", "mp3", "aac", "m4a"].contains((path as NSString).pathExtension)
    }

    private func start(_ c: Channel, urlString: String, forced: Active? = nil) {
        stopEngines()
        channel = c
        store?.markPlayed(c)
        failure = nil
        isBuffering = true
        isPlaying = false
        audioTracks = []
        selectedAudioTrack = nil
        didFallback = false
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed)
                ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:)) else {
            failure = String(localized: "Invalid stream address")
            isBuffering = false
            return
        }
        currentURL = url
        try? AVAudioSession.sharedInstance().setActive(true)
        let engine: Active
        if let forced {
            engine = forced
        } else {
            switch preference {
            case .mpv: engine = .mpv
            case .system: engine = Self.prefersSystem(url) && !Self.hostNeedsMPV(url) ? .system : .mpv
            }
        }
        switch engine {
        case .system: startSystem(url)
        default: startMPV(url)
        }
        updateNowPlaying()
    }

    private func stopEngines() {
        attempt += 1
        itemObservers = []
        audioGroup = nil
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        if active == .mpv { mpv.stop() }
        active = .none
        isPlaying = false
    }

    private func startMPV(_ url: URL) {
        active = .mpv
        attempt += 1
        let token = attempt
        mpv.setFill(fill)
        mpv.load(url, userAgent: userAgent)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.attempt == token, self.active == .mpv, !self.isPlaying, self.failure == nil else { return }
            self.failure = String(localized: "The stream did not start in time")
            self.isBuffering = false
        }
    }

    private func mpvEvent(_ e: MPVEngine.Event) {
        guard active == .mpv else { return }
        switch e {
        case .loading:
            isBuffering = true
        case .playing:
            isBuffering = false
            isPlaying = true
            failure = nil
            audioTracks = mpv.audioTracks()
            selectedAudioTrack = mpv.selectedAudioTrack
        case .buffering(let b):
            isBuffering = b
        case .paused(let p):
            if p { isPlaying = false } else if !isBuffering && failure == nil { isPlaying = true }
        case .failed(let message):
            failure = message
            isBuffering = false
            isPlaying = false
        case .ended:
            if isPlaying {
                isPlaying = false
                isBuffering = false
                failure = String(localized: "The broadcast has ended")
            }
        }
    }

    private func startSystem(_ url: URL) {
        active = .system
        attempt += 1
        let token = attempt
        var options: [String: Any] = [:]
        options[AVURLAssetHTTPUserAgentKey] = userAgent
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.preferredForwardBufferDuration = 3
        itemObservers = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                let error = item.error?.localizedDescription
                Task { @MainActor in self?.itemStatusChanged(status, error: error, token: token) }
            },
        ]
        avPlayer.replaceCurrentItem(with: item)
        applyFill()
        avPlayer.play()
        Task { [weak self] in
            // a live stream that the system player can open starts within a few seconds
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.attempt == token, self.active == .system, !self.isPlaying else { return }
            self.systemFailed(String(localized: "The stream did not start in time"))
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?, token: Int) {
        guard token == attempt, active == .system else { return }
        switch status {
        case .readyToPlay:
            if let item = avPlayer.currentItem { Task { await loadSystemAudioTracks(item, token: token) } }
        case .failed:
            systemFailed(error ?? String(localized: "Could not play this stream"))
        default:
            break
        }
    }

    private func systemFailed(_ message: String) {
        if preference == .system, !didFallback, let url = currentURL {
            didFallback = true
            Self.rememberMPV(for: url)          // next channels of this server go straight to MPV
            itemObservers = []
            avPlayer.replaceCurrentItem(with: nil)
            startMPV(url)
            return
        }
        failure = message
        isBuffering = false
        isPlaying = false
    }

    private func timeControlChanged(_ s: AVPlayer.TimeControlStatus) {
        guard active == .system else { return }
        switch s {
        case .playing:
            isPlaying = true
            isBuffering = false
            failure = nil
        case .waitingToPlayAtSpecifiedRate:
            isBuffering = true
        case .paused:
            isPlaying = false
        @unknown default:
            break
        }
    }

    private func loadSystemAudioTracks(_ item: AVPlayerItem, token: Int) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), token == attempt else { return }
        audioGroup = group
        audioTracks = group.options.enumerated().map { AudioTrack(id: $0.offset, name: $0.element.displayName) }
        if let sel = item.currentMediaSelection.selectedMediaOption(in: group) {
            selectedAudioTrack = group.options.firstIndex(of: sel)
        }
    }

    private static let fallbackHostsKey = "mpvHosts"

    private static func hostNeedsMPV(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        return (UserDefaults.standard.stringArray(forKey: fallbackHostsKey) ?? []).contains(h)
    }

    private static func rememberMPV(for url: URL) {
        guard let h = url.host?.lowercased() else { return }
        var list = UserDefaults.standard.stringArray(forKey: fallbackHostsKey) ?? []
        guard !list.contains(h) else { return }
        list.append(h)
        UserDefaults.standard.set(Array(list.suffix(50)), forKey: fallbackHostsKey)
    }

    private func applyFill() {
        avView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        if active == .mpv { mpv.setFill(fill) }
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
            Task { @MainActor in
                guard let self else { return }
                if self.active == .system { self.avPlayer.play() } else if self.active == .mpv { self.mpv.setPaused(false) }
            }
            return .success
        }
        rc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.active == .system { self.avPlayer.pause() } else if self.active == .mpv { self.mpv.setPaused(true) }
            }
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

extension PlayerController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        // let the user keep browsing channels while the video floats
        Task { @MainActor in self.isPresented = false }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            if !self.isPresented, self.channel != nil { self.close() }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            self.isPresented = true
            completionHandler(true)
        }
    }
}
