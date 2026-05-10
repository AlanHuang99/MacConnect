import Foundation
import UserNotifications

enum Notifier {
    static func show(title: String, body: String) async {
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
