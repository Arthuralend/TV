import Foundation
import UserNotifications

/// "Remind me" for upcoming programmes: a local notification 5 minutes before the start.
@MainActor
final class Reminders: ObservableObject {
    @Published private(set) var keys: Set<String>
    @Published var deniedAlert = false
    private let defaultsKey = "reminders"

    init() {
        keys = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
        Task { await prune() }
    }

    static func key(_ c: Channel, _ p: Programme) -> String { "\(c.id)|\(Int(p.start.timeIntervalSince1970))" }

    func isSet(_ c: Channel, _ p: Programme) -> Bool { keys.contains(Self.key(c, p)) }

    func toggle(_ c: Channel, _ p: Programme) async {
        let k = Self.key(c, p)
        let center = UNUserNotificationCenter.current()
        if keys.contains(k) {
            center.removePendingNotificationRequests(withIdentifiers: [k])
            keys.remove(k)
            save()
            return
        }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { deniedAlert = true; return }
        let content = UNMutableNotificationContent()
        content.title = c.name
        let time = p.start.hm
        content.body = String(localized: "Starts at \(time): \(p.title)")
        content.sound = .default
        content.userInfo = ["channelId": c.id]
        let fire = max(p.start.addingTimeInterval(-5 * 60), Date().addingTimeInterval(5))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: k, content: content, trigger: trigger))
            keys.insert(k)
            save()
        } catch {}
    }

    private func prune() async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
        keys = keys.intersection(pending)
        save()
    }

    private func save() { UserDefaults.standard.set(Array(keys), forKey: defaultsKey) }
}
