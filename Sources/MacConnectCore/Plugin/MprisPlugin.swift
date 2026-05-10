import Foundation

public final class MprisPlugin: Plugin, @unchecked Sendable {
    public let identifier = "mpris"
    public let displayName = "Media Control"
    public let incomingCapabilities = [PacketType.mpris]
    public let outgoingCapabilities = [PacketType.mprisRequest]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        // TODO: parse player state, store, expose via MprisStore for menu UI
        Log.plugin.debug("MPRIS packet received (parser not yet implemented)")
    }

    @MainActor
    public static func playPause(_ device: Device) {
        device.send(NetworkPacket(
            type: PacketType.mprisRequest,
            body: ["action": .string("PlayPause")]
        ))
    }
}
