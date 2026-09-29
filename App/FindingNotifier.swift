import Foundation
import UserNotifications

enum FindingNotifier {
    /// A loose binary from `swift run` has no bundle identifier. NotificationCenter raises if one is missing.
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    static func prepare() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
