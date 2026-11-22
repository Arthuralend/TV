import AVFoundation
import SwiftUI
import UIKit
import UserNotifications

@main
struct TVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: TVStore
    @StateObject private var player: PlayerController
    @StateObject private var reminders = Reminders()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Prefs.register()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let store = TVStore()
        let player = PlayerController()
        player.store = store
        _store = StateObject(wrappedValue: store)
        _player = StateObject(wrappedValue: player)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(player)
                .environmentObject(reminders)
                .preferredColorScheme(.dark)
                .tint(Theme.orange)
                .onOpenURL { url in
                    if url.isFileURL { store.importFile(url) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .openChannel)) { note in
                    guard let id = note.object as? String, let c = store.channel(withId: id) else { return }
                    player.open(c, queue: store.channels)
                }
        }
        .onChange(of: scenePhase) { phase in
            player.scenePhaseChanged(phase)
            if phase == .active { store.refreshIfStale() }
        }
    }
}

extension Notification.Name {
    static let openChannel = Notification.Name("TV.openChannel")
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .allButUpsideDown
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["channelId"] as? String
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openChannel, object: id)
        }
        completionHandler()
    }
}
