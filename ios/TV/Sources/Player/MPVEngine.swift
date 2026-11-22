import Foundation
import Libmpv
import UIKit

/// CAMetalLayer with the MoltenVK workarounds from the MPVKit demo.
final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK sets drawableSize to 1x1 to force a presentation: ignore it (flicker / stuck 1x1)
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set { if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue } }
    }

    // EDR mode can only be switched on the main thread
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}

final class MPVVideoView: UIView {
    let metalLayer = MPVMetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        CATransaction.commit()
    }
}

/// libmpv (mpv + FFmpeg) player. One mpv instance is created once and reused:
/// switching channels is a `loadfile … replace`, which is fast.
final class MPVEngine {
    enum Event {
        case loading
        case playing
        case buffering(Bool)
        case paused(Bool)
        case failed(String)
        case ended
    }

    let view = MPVVideoView()
    /// Called on the main thread.
    var onEvent: (@MainActor (Event) -> Void)?

    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "tv.mpv.events", qos: .userInitiated)

    private func setup() {
        guard mpv == nil, let ctx = mpv_create() else { return }
        mpv = ctx
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(view.metalLayer).toOpaque()))
        mpv_set_option(ctx, "wid", MPV_FORMAT_INT64, &wid)
        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("video-rotate", "no"),
            ("ytdl", "no"),
            ("idle", "yes"),
            ("keep-open", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("audio-display", "no"),
            ("sub-auto", "no"),
            // IPTV: start fast, survive short network drops
            ("cache", "yes"),
            ("cache-pause-initial", "no"),
            ("demuxer-max-bytes", "64MiB"),
            ("demuxer-max-back-bytes", "16MiB"),
            ("demuxer-lavf-analyzeduration", "1"),
            ("network-timeout", "15"),
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=4"),
            ("hls-bitrate", "max"),
        ]
        for (k, v) in options { mpv_set_option_string(ctx, k, v) }
        mpv_initialize(ctx)
        mpv_observe_property(ctx, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(ctx, 0, "idle-active", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(ctx, { raw in
            guard let raw else { return }
            let engine = Unmanaged<MPVEngine>.fromOpaque(raw).takeUnretainedValue()
            engine.readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: control

    func load(_ url: URL, userAgent: String) {
        setup()
        guard mpv != nil else { onEvent?(.failed(String(localized: "Could not play this stream"))); return }
        setString("user-agent", userAgent)
        setFlag("pause", false)
        command(["loadfile", url.absoluteString, "replace"])
    }

    func stop() {
        guard mpv != nil else { return }
        command(["stop"])
    }

    func setPaused(_ paused: Bool) { setFlag("pause", paused) }

    var isPaused: Bool { getFlag("pause") }

    /// Seconds from the start of the current stream.
    var position: Double { getDouble("time-pos") }

    /// Fill the screen by cropping (panscan) instead of letterboxing.
    func setFill(_ fill: Bool) { setString("panscan", fill ? "1.0" : "0.0") }

    /// Stops drawing video in the background; the sound keeps playing.
    func setVideoEnabled(_ on: Bool) { setString("vid", on ? "auto" : "no") }

    func audioTracks() -> [AudioTrack] {
        let count = Int(getDouble("track-list/count"))
        guard count > 0 else { return [] }
        var list: [AudioTrack] = []
        for i in 0..<count where getString("track-list/\(i)/type") == "audio" {
            guard let id = Int(getString("track-list/\(i)/id") ?? "") else { continue }
            let lang = getString("track-list/\(i)/lang")
            let title = getString("track-list/\(i)/title")
            let codec = getString("track-list/\(i)/codec")
            let name = [title, lang?.uppercased()].compactMap { $0 }.joined(separator: " · ")
            list.append(AudioTrack(id: id, name: name.isEmpty ? String(localized: "Track \(id)") + (codec.map { " (\($0))" } ?? "") : name))
        }
        return list
    }

    var selectedAudioTrack: Int? { Int(getString("aid") ?? "") }

    func selectAudioTrack(_ id: Int) { setString("aid", String(id)) }

    // MARK: libmpv helpers

    private func command(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(UnsafeMutablePointer(mutating: p)) } }
        mpv_command_async(mpv, 0, &cargs)
    }

    private func setString(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_property_string(mpv, name, value)
    }

    private func setFlag(_ name: String, _ on: Bool) {
        guard let mpv else { return }
        var v: Int32 = on ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &v)
    }

    private func getFlag(_ name: String) -> Bool {
        guard let mpv else { return false }
        var v: Int32 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &v)
        return v != 0
    }

    private func getDouble(_ name: String) -> Double {
        guard let mpv else { return 0 }
        var v: Double = 0
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
        return v.isFinite ? v : 0
    }

    private func getString(_ name: String) -> String? {
        guard let mpv, let c = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(c) }
        return String(cString: c)
    }

    // MARK: events

    private func readEvents() {
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            while true {
                guard let event = mpv_wait_event(mpv, 0) else { break }
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { break }
                switch id {
                case MPV_EVENT_START_FILE:
                    self.emit(.loading)
                case MPV_EVENT_PLAYBACK_RESTART:
                    self.emit(.playing)
                case MPV_EVENT_END_FILE:
                    if let data = event.pointee.data {
                        let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        if end.error < 0 {
                            self.emit(.failed(String(cString: mpv_error_string(end.error))))
                        }
                    }
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let data = event.pointee.data else { break }
                    let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                    let name = String(cString: prop.name)
                    guard prop.format == MPV_FORMAT_FLAG, let value = prop.data else { break }
                    let on = value.assumingMemoryBound(to: Int32.self).pointee != 0
                    if name == "paused-for-cache" { self.emit(.buffering(on)) }
                    if name == "pause" { self.emit(.paused(on)) }
                    if name == "idle-active", on { self.emit(.ended) }
                default:
                    break
                }
            }
        }
    }

    private func emit(_ e: Event) {
        Task { @MainActor [weak self] in self?.onEvent?(e) }
    }
}
