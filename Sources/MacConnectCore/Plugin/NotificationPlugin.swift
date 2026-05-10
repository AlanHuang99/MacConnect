import Foundation

public final class NotificationPlugin: Plugin, @unchecked Sendable {
    public let identifier = "notification"
    public let displayName = "Notifications"
    public let incomingCapabilities = [PacketType.notification, PacketType.notificationRequest]
    public let outgoingCapabilities = [PacketType.notificationReply, PacketType.notificationAction, PacketType.notificationRequest]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        let title = packet.body["title"]?.stringValue
        let fallback = device.name
        let appName = packet.body["appName"]?.stringValue ?? fallback
        let text = packet.body["text"]?.stringValue ?? packet.body["ticker"]?.stringValue
        let isCancel = packet.body["isCancel"]?.boolValue ?? false
        if isCancel { return }
        let composed = [title, text].compactMap { $0 }.joined(separator: "\n")
        await Notifier.show(title: appName, body: composed.isEmpty ? "Notification" : composed)
    }
}
