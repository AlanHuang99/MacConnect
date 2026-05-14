import Foundation
import UserNotifications

/// Posts macOS notifications. When a `replyContext` is supplied, attaches
/// the "Reply" text-input action so the user can answer the originating
/// peer's notification directly from the banner — see `NotificationReplyRouter`
/// for how the typed reply is routed back to the peer.
public enum Notifier {
    public struct ReplyContext: Sendable {
        public let deviceId: String
        public let requestReplyId: String
    }

    public static let replyCategoryIdentifier = "macconnect.notification.reply"
    public static let replyActionIdentifier = "macconnect.notification.reply.action"
    public static let userInfoDeviceId = "macconnect.deviceId"
    public static let userInfoRequestReplyId = "macconnect.requestReplyId"

    /// Register the reply category with UNUserNotificationCenter. Idempotent;
    /// safe to call multiple times from app startup.
    public static func registerCategories() {
        let action = UNTextInputNotificationAction(
            identifier: replyActionIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply…"
        )
        let category = UNNotificationCategory(
            identifier: replyCategoryIdentifier,
            actions: [action],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    public static func show(title: String, body: String, replyContext: ReplyContext? = nil) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let ctx = replyContext {
            content.categoryIdentifier = replyCategoryIdentifier
            content.userInfo = [
                userInfoDeviceId: ctx.deviceId,
                userInfoRequestReplyId: ctx.requestReplyId
            ]
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(req)
        } catch {
            // User has not granted notification permission, or system suppressed it.
            Log.plugin.notice("Notification post failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
