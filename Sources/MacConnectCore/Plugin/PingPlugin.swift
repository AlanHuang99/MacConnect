import Foundation
import UserNotifications

public final class PingPlugin: Plugin, @unchecked Sendable {
    public let identifier = "ping"
    public let displayName = "Ping"
    public let incomingCapabilities = [PacketType.ping]
    public let outgoingCapabilities = [PacketType.ping]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        let message = packet.body["message"]?.stringValue ?? "Ping!"
        let name = device.name
        Log.plugin.info("Ping from \(name, privacy: .public): \(message, privacy: .public)")
        await Notifier.show(title: "Ping from \(name)", body: message)
    }

    @MainActor
    public static func send(to device: Device, message: String? = nil) {
        var body: [String: AnyJSON] = [:]
        if let message {
            body["message"] = .string(message)
        }
        device.send(NetworkPacket(type: PacketType.ping, body: body))
    }
}
