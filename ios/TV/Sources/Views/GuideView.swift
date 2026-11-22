import SwiftUI

/// "What's on": every channel's programme at the chosen time.
struct GuideView: View {
    @EnvironmentObject private var store: TVStore
    @State private var slot = GuideSlot(date: nil)
    @State private var group: String?
    @State private var search = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.playlists.isEmpty {
                    WelcomeView()
                } else if !store.guideEnabled {
                    VStack(spacing: 16) {
                        EmptyStateView(icon: "calendar.badge.minus", title: "TV guide is off",
                                       message: "Turn it on to see what's on now and next.")
                            .frame(maxHeight: 260)
                        Button("Turn On") { store.setGuideEnabled(true) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
            .background(Theme.background)
            .navigationTitle(Text("TV Guide"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.groups.count > 1 {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Picker(selection: $group) {
                                Text("All Groups").tag(String?.none)
                                ForEach(store.groups, id: \.self) { Text(verbatim: $0).tag(Optional($0)) }
                            } label: {
                                Text("Group")
                            }
                        } label: {
                            Image(systemName: group == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                                .accessibilityLabel(Text("Group"))
                        }
                    }
                }
            }
            .navigationDestination(for: Channel.self) { ScheduleView(channel: $0) }
        }
        .onChange(of: store.selectedPlaylistID) { _ in group = nil }
    }

    private var slots: [GuideSlot] {
        let cal = Calendar.current
        let hour = cal.dateInterval(of: .hour, for: Date())?.start ?? Date()
        return [GuideSlot(date: nil)] + (1...24).compactMap { cal.date(byAdding: .hour, value: $0, to: hour) }.map { GuideSlot(date: $0) }
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let at = slot.date ?? ctx.date
            let rows: [GuideEntry] = store.channels(in: group, search: search).compactMap { c in
                store.epg.programme(for: c, at: at).map { GuideEntry(channel: c, programme: $0) }
            }
            VStack(spacing: 0) {
                ChipBar(items: slots, selection: $slot) { $0.title }
                if store.epgStatus.isBusy && rows.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        (store.epgStatus == .processing ? Text("Processing the TV guide…") : Text("Downloading the TV guide…"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    EmptyStateView(icon: "calendar.badge.exclamationmark", title: "No TV guide",
                                   message: "Your playlist has no TV guide for this time. You can add an XMLTV link in the playlist settings.")
                } else {
                    List(rows) { row in
                        NavigationLink(value: row.channel) {
                            GuideRow(channel: row.channel, programme: row.programme, now: ctx.date)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .searchable(text: $search, prompt: Text("Search channels"))
        .refreshable { store.reloadGuide() }
    }
}

struct GuideEntry: Identifiable {
    let channel: Channel
    let programme: Programme
    var id: String { channel.id }
}

struct GuideSlot: Hashable {
    let date: Date?

    var title: String {
        guard let date else { return String(localized: "Now") }
        if Calendar.current.isDateInToday(date) { return date.hm }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

private struct GuideRow: View {
    let channel: Channel
    let programme: Programme
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            LogoView(channel: channel, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: channel.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(verbatim: programme.title).font(.body.weight(.semibold)).lineLimit(2)
                HStack(spacing: 8) {
                    Text(verbatim: "\(programme.start.hm) – \(programme.stop.hm)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if programme.isLive(at: now) {
                        ProgressLine(value: programme.progress(at: now)).frame(maxWidth: 120)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
