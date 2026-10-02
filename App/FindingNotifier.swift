import Foundation
import UserNotifications

@MainActor
public enum FindingNotifier {
    public enum Authorization: Equatable, Sendable {
        case unavailable, notDetermined, allowed, denied

        public var description: String {
            switch self {
            case .unavailable: "Available in the packaged app"
            case .notDetermined: "Permission not requested"
            case .allowed: "Notifications allowed"
            case .denied: "Notifications are turned off for this app in System Settings"
            }
        }
    }

    private static var queued: [(title: String, body: String, findingID: UUID?)] = []
    private static var pending: Task<Void, Never>?
    /// A loose binary from `swift run` has no bundle identifier. NotificationCenter raises if one is missing.
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    /// Routes notification clicks. Must run before launch finishes so a click that relaunches is not lost.
    static func install(open: @escaping @MainActor (UUID?) -> Void) {
        guard canNotify else { return }
        NotificationRouter.shared.open = open
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    static func requestAuthorization() async -> Authorization {
        guard canNotify else { return .unavailable }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    static func authorization() async -> Authorization {
        guard canNotify else { return .unavailable }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    /// Updates arriving together become one notification, so a scan cannot flood Notification Center.
    static func notify(title: String, body: String, findingID: UUID?) {
        guard canNotify else { return }
        queued.append((title, body, findingID))
        guard pending == nil else { return }
        pending = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            let notices = queued
            queued = []; pending = nil
            let content = UNMutableNotificationContent()
            if notices.count == 1 {
                content.title = notices[0].title; content.body = notices[0].body
                if let id = notices[0].findingID { content.userInfo = ["findingID": id.uuidString] }
            } else {
                content.title = "Synology Drive Unstuckerator"
                content.body = "\(notices.count) files changed state. "
                    + notices.prefix(3).map { $0.title + ": " + $0.body }.joined(separator: "\n")
            }
            content.sound = .default
            content.threadIdentifier = "findings"
            let request = UNNotificationRequest(identifier: "drive-status", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

/// Opens Activity on the file a notification is about, and shows banners while a window is frontmost.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    var open: @MainActor (UUID?) -> Void = { _ in }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["findingID"] as? String).flatMap(UUID.init(uuidString:))
        await open(id)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
