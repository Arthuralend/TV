import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: TVStore
    @AppStorage(Prefs.engine) private var engine = PlayerEngine.auto.rawValue
    @AppStorage(Prefs.networkCaching) private var networkCaching = 1500
    @AppStorage(Prefs.useLogoDB) private var useLogoDB = true
    @AppStorage(Prefs.useDefaultEPG) private var useDefaultEPG = true
    @State private var showEditor = false
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.playlists) { p in
                        NavigationLink {
                            PlaylistEditor(playlist: p)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: p.name)
                                    Text(kindTitle(p.kind)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if p.id == store.selectedPlaylistID {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.orange)
                                        .accessibilityLabel(Text("Selected"))
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.remove(p) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    Button {
                        showEditor = true
                    } label: {
                        Label("Add Playlist", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Playlists")
                } footer: {
                    Text("TV does not provide any channels or streams. Use only playlists you have the right to watch.")
                }

                Section {
                    Toggle("Built-in guide sources", isOn: $useDefaultEPG)
                    HStack {
                        Text("Updated")
                        Spacer()
                        switch store.epgStatus {
                        case .loading:
                            ProgressView()
                        case .failed:
                            Text("Failed").foregroundStyle(.red)
                        case .idle:
                            if let d = store.epgUpdated {
                                Text(d.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                            } else {
                                Text("Never").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Update TV Guide Now") { store.reloadGuide() }
                        .disabled(store.selectedPlaylist == nil || store.epgStatus == .loading)
                } header: {
                    Text("TV Guide")
                } footer: {
                    Text("The guide named in your playlist is used first. Built-in sources add a public XMLTV guide for channels that have none.")
                }

                Section {
                    Picker("Player", selection: $engine) {
                        ForEach(PlayerEngine.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Stepper(value: $networkCaching, in: 300...10000, step: 500) {
                        HStack {
                            Text("VLC buffer")
                            Spacer()
                            Text(verbatim: "\(networkCaching) ms").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Automatic uses the system player for HLS (Picture in Picture, AirPlay) and VLC for other stream types.")
                }

                Section {
                    Toggle("Find missing logos", isOn: $useLogoDB)
                    Button("Clear Cache") {
                        Task {
                            await LogoCache.shared.clear()
                            EPGService.clearCache()
                            cleared = true
                        }
                    }
                } header: {
                    Text("Logos & Storage")
                } footer: {
                    Text("Missing channel logos are looked up in the open iptv-org database.")
                }

                Section {
                    Link(destination: AppLinks.privacy) { Label("Privacy Policy", systemImage: "hand.raised") }
                    Link(destination: AppLinks.terms) { Label("Terms of Use", systemImage: "doc.text") }
                    Link(destination: AppLinks.support) { Label("Support", systemImage: "questionmark.circle") }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(verbatim: appVersion).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(Text("Settings"))
            .sheet(isPresented: $showEditor) { PlaylistEditor(playlist: nil) }
            .alert(Text("Cache cleared"), isPresented: $cleared) { Button("OK") {} }
        }
    }

    private func kindTitle(_ k: PlaylistKind) -> LocalizedStringKey {
        switch k {
        case .url: return "M3U link"
        case .file: return "File"
        case .xtream: return "Xtream Codes"
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
