import Foundation
import UserNotifications

/// Posts local macOS notifications for user-visible app events.
public enum Notifier {
    /// Kept as an idempotent hook so startup code does not need special
    /// cases when richer notification categories return in a future build.
    public static func registerCategories() {
        UNUserNotificationCenter.current().setNotificationCategories([])
    }

    public static func show(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(req)
        } catch {
            // User has not granted notification permission, or system suppressed it.
            Log.plugin.notice("Notification post failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
