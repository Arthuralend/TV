import SwiftUI
import UniformTypeIdentifiers

/// Add (playlist == nil, shown as a sheet) or edit (pushed from Settings) a playlist.
struct PlaylistEditor: View {
    let playlist: Playlist?
    @EnvironmentObject private var store: TVStore
    @Environment(\.dismiss) private var dismiss

    @State private var kind: PlaylistKind = .url
    @State private var name = ""
    @State private var link = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var epg = ""
    @State private var userAgent = ""
    @State private var refreshHours = 24
    @State private var fileName: String?
    @State private var pickedFile: URL?
    @State private var showImporter = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var loaded = false

    var body: some View {
        if playlist == nil {
            NavigationStack { form }
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            if playlist == nil {
                Section {
                    Picker("Type", selection: $kind) {
                        Text("Link").tag(PlaylistKind.url)
                        Text("File").tag(PlaylistKind.file)
                        Text("Xtream Codes").tag(PlaylistKind.xtream)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section {
                TextField("Name", text: $name)
                switch kind {
                case .url:
                    TextField("M3U / M3U8 link", text: $link, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .file:
                    Button {
                        showImporter = true
                    } label: {
                        HStack {
                            Label(fileName ?? String(localized: "Choose File…"), systemImage: "doc")
                            Spacer()
                        }
                    }
                case .xtream:
                    TextField("Server (http://example.com:8080)", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
            } footer: {
                switch kind {
                case .url: Text("The link to your M3U playlist from your TV provider.")
                case .file: Text("An .m3u or .m3u8 file from the Files app.")
                case .xtream: Text("Login details from your TV provider. Only live channels are added.")
                }
            }

            Section {
                TextField("TV guide (XMLTV) link", text: $epg, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if kind != .file {
                    TextField("User-Agent", text: $userAgent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Auto-update", selection: $refreshHours) {
                        Text("Every 6 hours").tag(6)
                        Text("Every 12 hours").tag(12)
                        Text("Daily").tag(24)
                        Text("Weekly").tag(168)
                        Text("Never").tag(0)
                    }
                }
            } header: {
                Text("Optional")
            } footer: {
                Text("Leave the guide empty to use the one named in the playlist.")
            }

            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }

            if let playlist {
                Section {
                    if playlist.id != store.selectedPlaylistID {
                        Button("Use This Playlist") { store.select(playlist.id); dismiss() }
                    }
                    Button("Delete Playlist", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(playlist == nil ? Text("New Playlist") : Text("Playlist"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if playlist == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!isValid)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.fileTypes) { result in
            if case .success(let url) = result {
                pickedFile = url
                fileName = url.lastPathComponent
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            }
        }
        .confirmationDialog(Text("Delete this playlist?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let playlist { store.remove(playlist) }
                dismiss()
            }
        }
        .onAppear(perform: fill)
    }

    private static var fileTypes: [UTType] {
        var types: [UTType] = [.m3uPlaylist]
        if let t = UTType(filenameExtension: "m3u8") { types.append(t) }
        types += [.plainText, .text, .data]
        return types
    }

    private var isValid: Bool {
        switch kind {
        case .url:
            let t = link.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t.hasPrefix("http://") || t.hasPrefix("https://")
        case .file:
            return pickedFile != nil || playlist != nil
        case .xtream:
            return !server.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty
        }
    }

    private func fill() {
        guard !loaded else { return }
        loaded = true
        guard let p = playlist else { return }
        kind = p.kind
        name = p.name
        epg = p.epgURL ?? ""
        userAgent = p.userAgent ?? ""
        refreshHours = p.autoRefreshHours
        switch p.kind {
        case .url: link = p.source
        case .file: fileName = String(localized: "Imported file")
        case .xtream:
            server = p.source
            username = p.username ?? ""
            password = p.password ?? ""
        }
    }

    private func save() {
        error = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmedName.isEmpty ? String(localized: "Playlist \(store.playlists.count + 1)") : trimmedName
        var p = playlist ?? Playlist(name: finalName, kind: kind, source: "")
        p.name = finalName
        p.kind = kind
        p.epgURL = epg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : epg.trimmingCharacters(in: .whitespacesAndNewlines)
        p.userAgent = userAgent.trimmingCharacters(in: .whitespaces).isEmpty ? nil : userAgent.trimmingCharacters(in: .whitespaces)
        p.autoRefreshHours = refreshHours
        switch kind {
        case .url:
            p.source = link.trimmingCharacters(in: .whitespacesAndNewlines)
        case .file:
            if let pickedFile {
                do {
                    p.source = try PlaylistFiles.store(pickedFile)
                } catch {
                    self.error = String(localized: "Could not open the file: \(error.localizedDescription)")
                    return
                }
            }
        case .xtream:
            p.source = Xtream.normalizedServer(server)
            p.username = username.trimmingCharacters(in: .whitespaces)
            p.password = password
        }
        if playlist == nil { store.add(p) } else { store.update(p) }
        dismiss()
    }
}
