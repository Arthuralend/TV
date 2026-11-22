import SwiftUI

/// One channel's TV guide by day, with archive playback and reminders.
struct ScheduleView: View {
    let channel: Channel
    @EnvironmentObject private var store: TVStore
    @EnvironmentObject private var player: PlayerController
    @State private var day = Calendar.current.startOfDay(for: Date())

    var body: some View {
        let all = store.epg.schedule(for: channel)
        let days = ScheduleDays.days(in: all)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                LogoView(channel: channel, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: channel.name).font(.title3.weight(.bold)).lineLimit(2)
                    Text(verbatim: channel.group).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    player.open(channel, queue: store.channels(in: channel.group, search: ""))
                } label: {
                    Label("Watch", systemImage: "play.fill").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            if days.count > 1 {
                ChipBar(items: days, selection: $day) { ScheduleDays.title($0) }
            }
            let list = all.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
            if list.isEmpty {
                EmptyStateView(icon: "calendar.badge.exclamationmark", title: "No TV guide for this channel")
            } else {
                ProgrammeList(channel: channel, programmes: list)
            }
        }
        .background(Theme.background)
        .navigationTitle(Text(verbatim: channel.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    store.toggleFavorite(channel)
                } label: {
                    Image(systemName: store.isFavorite(channel) ? "star.fill" : "star")
                        .accessibilityLabel(store.isFavorite(channel) ? Text("Remove from Favorites") : Text("Add to Favorites"))
                }
            }
        }
    }
}

enum ScheduleDays {
    static func days(in list: [Programme]) -> [Date] {
        let cal = Calendar.current
        var seen = Set<Date>()
        return list.map { cal.startOfDay(for: $0.start) }.filter { seen.insert($0).inserted }.sorted()
    }

    static func title(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return String(localized: "Today") }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
        if cal.isDateInTomorrow(d) { return String(localized: "Tomorrow") }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

struct ProgrammeList: View {
    let channel: Channel
    let programmes: [Programme]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            ScrollViewReader { proxy in
                List(programmes) { p in
                    ProgrammeRow(channel: channel, programme: p, now: ctx.date)
                        .id(p.id)
                        .listRowBackground(p.isLive(at: ctx.date) ? Theme.orange.opacity(0.12) : Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear {
                    if let cur = programmes.first(where: { $0.stop > Date() }) {
                        proxy.scrollTo(cur.id, anchor: .top)
                    }
                }
            }
        }
    }
}

private struct ProgrammeRow: View {
    let channel: Channel
    let programme: Programme
    let now: Date
    @EnvironmentObject private var store: TVStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var reminders: Reminders
    @State private var expanded = false

    private var isLive: Bool { programme.isLive(at: now) }
    private var isPast: Bool { programme.stop <= now }
    private var inArchive: Bool {
        guard channel.hasArchive, isPast else { return false }
        let limit = now.addingTimeInterval(-Double(channel.catchupDays ?? 7) * 86400)
        return programme.start >= limit
    }
    private var onScreen: Bool {
        player.channel?.id == channel.id && player.isArchive
            && programme.start <= player.positionDate && programme.stop > player.positionDate
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: programme.start.hm)
                .font(.subheadline.monospacedDigit().weight(isLive ? .bold : .regular))
                .foregroundStyle(isLive ? Theme.orange : (isPast ? Color.secondary : Color.primary))
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: programme.title)
                    .font(.body.weight(isLive ? .semibold : .regular))
                    .foregroundStyle(isPast && !inArchive ? Color.secondary : Color.primary)
                    .lineLimit(expanded ? nil : 2)
                if isLive {
                    ProgressLine(value: programme.progress(at: now)).frame(maxWidth: 160)
                }
                if expanded, let d = programme.desc {
                    Text(verbatim: d).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if programme.desc != nil { withAnimation { expanded.toggle() } } }
            action
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var action: some View {
        if isLive {
            Button {
                if !(player.channel?.id == channel.id && !player.isArchive) {
                    player.open(channel, queue: store.channels(in: channel.group, search: ""))
                }
            } label: {
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.red))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderless)
        } else if inArchive {
            Button {
                player.openArchive(channel, from: programme.start, queue: store.channels(in: channel.group, search: ""))
            } label: {
                Image(systemName: onScreen ? "speaker.wave.2.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.orange)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Watch from the archive"))
        } else if !isPast {
            let set = reminders.isSet(channel, programme)
            Button {
                Task { await reminders.toggle(channel, programme) }
            } label: {
                Image(systemName: set ? "bell.fill" : "bell")
                    .font(.title3)
                    .foregroundStyle(set ? Theme.orange : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(set ? Text("Cancel reminder") : Text("Remind me"))
        }
    }
}
