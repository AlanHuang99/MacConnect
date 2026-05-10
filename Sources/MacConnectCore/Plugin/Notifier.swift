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
            // Banner permission may not be granted; log and continue
            Log.plugin.notice("Notification post failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func showAction(title: String, body: String, actions: [String]) async {
        // Action support is not yet wired up; for now this just shows a banner.
        await show(title: title, body: body)
    }
}
