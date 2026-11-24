import EnergyCore
import Foundation
import UserNotifications

/// Posts local notifications decided by `NotificationEvaluator`. Used by the app, the background task
/// and the widget extension (whichever refresh notices the event first).
enum NotificationDelivery {
    static func deliver(_ items: [EnergyNotification]) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            // Groups notifications per inverter in Notification Center.
            content.threadIdentifier = item.inverterId.rawValue
            content.userInfo = ["inverterId": item.inverterId.rawValue, "kind": item.kind.rawValue]
            // Same identifier → iOS replaces instead of duplicating (app and widget may race).
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil))
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
