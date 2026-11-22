import AVKit
import SwiftUI
import UIKit

struct PlayerScreen: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: TVStore
    @Environment(\.verticalSizeClass) private var vSize
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    private var landscape: Bool { vSize == .compact }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if landscape {
                video.ignoresSafeArea()
            } else {
                VStack(spacing: 0) {
                    video.aspectRatio(16 / 9, contentMode: .fit)
                    PlayerInfoPanel()
                }
            }
        }
        .statusBarHidden(landscape)
        .persistentSystemOverlays(landscape ? .hidden : .automatic)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            showControls()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var video: some View {
        ZStack {
            VideoSurface(player: player)
            if player.isBuffering && player.failure == nil {
                ProgressView().controlSize(.large).tint(.white)
            }
            if let failure = player.failure {
                failureView(failure)
            }
            if controlsVisible {
                PlayerControls(landscape: landscape, onInteract: showControls)
                    .transition(.opacity)
            }
            if let toast = player.toast {
                VStack {
                    Spacer()
                    Text(verbatim: toast)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.bottom, 70)
                }
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if controlsVisible {
                withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
            } else {
                showControls()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                if abs(dx) > abs(dy) * 1.5 {
                    player.step(dx < 0 ? 1 : -1)
                    showControls()
                } else if dy > 120, !landscape {
                    player.close()
                }
            }
        )
        .animation(.easeOut(duration: 0.2), value: player.toast)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text("Could not play the channel").font(.headline)
            Text(verbatim: message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Retry") { player.retry() }.buttonStyle(.borderedProminent)
                Button {
                    player.retry(engine: player.active == .vlc ? .system : .vlc)
                } label: {
                    player.active == .vlc ? Text("Try System Player") : Text("Try VLC")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: 420)
    }

    private func showControls() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled, player.isPlaying else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

/// Hosts the active engine's video view.
struct VideoSurface: UIViewRepresentable {
    @ObservedObject var player: PlayerController

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.clipsToBounds = true
        attach(to: v)
        return v
    }

    func updateUIView(_ v: UIView, context: Context) { attach(to: v) }

    private func attach(to v: UIView) {
        let target: UIView = player.active == .vlc ? player.vlcView : player.avView
        let other: UIView = player.active == .vlc ? player.avView : player.vlcView
        if other.superview === v { other.removeFromSuperview() }
        if target.superview !== v {
            target.removeFromSuperview()
            target.frame = v.bounds
            target.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.addSubview(target)
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.orange)
        v.prioritizesVideoDevices = true
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private struct PlayerControls: View {
    let landscape: Bool
    let onInteract: () -> Void
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: TVStore

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer()
                centerButtons
                Spacer()
                bottomBar
            }
            .padding(.horizontal, landscape ? 24 : 12)
            .padding(.vertical, landscape ? 16 : 8)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                player.close()
            } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 36, height: 36)
            }
            .accessibilityLabel(Text("Close"))
            if let c = player.channel {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: c.name).font(.headline).lineLimit(1)
                    if let p = store.epg.programme(for: c, at: player.positionDate) {
                        Text(verbatim: p.title).font(.caption).foregroundStyle(Color.white.opacity(0.75)).lineLimit(1)
                    }
                }
            }
            Spacer()
            AirPlayButton().frame(width: 36, height: 36)
            if player.active == .system && player.pipPossible {
                Button {
                    player.togglePiP()
                } label: {
                    Image(systemName: "pip.enter").font(.title3).frame(width: 36, height: 36)
                }
                .accessibilityLabel(Text("Picture in Picture"))
            }
            menu
        }
    }

    private var menu: some View {
        Menu {
            if player.audioTracks.count > 1 {
                Picker(selection: Binding(get: { player.selectedAudioTrack ?? -1 }, set: { player.selectAudioTrack($0); onInteract() })) {
                    ForEach(player.audioTracks) { Text(verbatim: $0.name).tag($0.id) }
                } label: {
                    Label("Audio Track", systemImage: "waveform")
                }
                .pickerStyle(.menu)
            }
            Toggle(isOn: $player.fill) { Label("Fill Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            Button {
                player.retry(engine: player.active == .vlc ? .system : .vlc)
            } label: {
                if player.active == .vlc {
                    Label("Play in System Player", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("Play in VLC", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let c = player.channel {
                Button {
                    store.toggleFavorite(c)
                } label: {
                    if store.isFavorite(c) {
                        Label("Remove from Favorites", systemImage: "star.slash")
                    } else {
                        Label("Add to Favorites", systemImage: "star")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).frame(width: 36, height: 36)
        }
        .accessibilityLabel(Text("More"))
    }

    private var centerButtons: some View {
        HStack(spacing: landscape ? 56 : 36) {
            Button { player.step(-1); onInteract() } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            .accessibilityLabel(Text("Previous Channel"))
            if canRewind {
                Button { player.jump(-30); onInteract() } label: {
                    Image(systemName: "gobackward.30").font(.title2)
                }
                .accessibilityLabel(Text("Back 30 Seconds"))
            }
            Button { player.togglePause(); onInteract() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .frame(width: 56, height: 56)
            }
            .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))
            if player.isArchive {
                Button { player.jump(30); onInteract() } label: {
                    Image(systemName: "goforward.30").font(.title2)
                }
                .accessibilityLabel(Text("Forward 30 Seconds"))
            }
            Button { player.step(1); onInteract() } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
            .accessibilityLabel(Text("Next Channel"))
        }
        .shadow(radius: 6)
    }

    private var canRewind: Bool { player.isArchive || (player.channel?.hasArchive ?? false) }

    private var bottomBar: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            HStack(spacing: 10) {
                if player.isArchive {
                    Button {
                        player.goLive()
                    } label: {
                        Text("ARCHIVE · LIVE ›").font(.caption2.weight(.heavy))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.orange))
                    }
                    .accessibilityLabel(Text("Back to Live"))
                    Text(verbatim: player.positionDate.hm).font(.caption.monospacedDigit())
                } else {
                    Text("LIVE").font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.red))
                }
                if let c = player.channel, let p = store.epg.programme(for: c, at: player.positionDate) {
                    Text(verbatim: p.start.hm).font(.caption2.monospacedDigit())
                    ProgressLine(value: p.progress(at: player.positionDate), height: 4)
                    Text(verbatim: p.stop.hm).font(.caption2.monospacedDigit())
                } else {
                    Spacer()
                }
                Button {
                    rotate()
                } label: {
                    Image(systemName: landscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(landscape ? Text("Exit Full Screen") : Text("Full Screen"))
            }
        }
    }

    private func rotate() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .portrait : .landscapeRight)) { _ in }
        onInteract()
    }
}

/// Under the video in portrait: what is on and the rest of the day.
private struct PlayerInfoPanel: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: TVStore

    var body: some View {
        if let c = player.channel {
            let today = store.epg.schedule(for: c).filter {
                Calendar.current.isDate($0.start, inSameDayAs: player.positionDate) || $0.isLive(at: player.positionDate)
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    LogoView(channel: c, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: c.name).font(.headline).lineLimit(1)
                        Text(verbatim: c.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        store.toggleFavorite(c)
                    } label: {
                        Image(systemName: store.isFavorite(c) ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(Theme.orange)
                    }
                    .accessibilityLabel(store.isFavorite(c) ? Text("Remove from Favorites") : Text("Add to Favorites"))
                }
                .padding()
                Divider()
                if today.isEmpty {
                    EmptyStateView(icon: "calendar", title: "No TV guide for this channel")
                } else {
                    ProgrammeList(channel: c, programmes: today)
                        .id(c.id)
                }
            }
            .background(Theme.background)
        } else {
            Theme.background
        }
    }
}
