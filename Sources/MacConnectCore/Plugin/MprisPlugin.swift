import Foundation

public final class MprisPlugin: Plugin, @unchecked Sendable {
    public let identifier = "mpris"
    public let displayName = "Media Control"
    public let incomingCapabilities = [PacketType.mpris]
    public let outgoingCapabilities = [PacketType.mprisRequest]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        MprisStore.shared.update(deviceId: device.id, with: packet)
    }

    /// Ask the peer to push its current player state. KDE Connect peers
    /// reply with an MPRIS packet carrying title/artist/isPlaying. Called
    /// when the popover opens so the UI doesn't show stale state.
    @MainActor
    public static func requestNowPlaying(from device: Device) {
        device.send(NetworkPacket(
            type: PacketType.mprisRequest,
            body: [
                "requestNowPlaying": .bool(true),
                "requestPlayerList": .bool(true),
            ]
        ))
    }

    @MainActor
    public static func playPause(_ device: Device) {
        sendAction(device, "PlayPause")
    }

    @MainActor
    public static func next(_ device: Device) {
        sendAction(device, "Next")
    }

    @MainActor
    public static func previous(_ device: Device) {
        sendAction(device, "Previous")
    }

    @MainActor
    private static func sendAction(_ device: Device, _ action: String) {
        var body: [String: AnyJSON] = ["action": .string(action)]
        if let player = MprisStore.shared.state(for: device.id)?.player {
            body["player"] = .string(player)
        }
        device.send(NetworkPacket(type: PacketType.mprisRequest, body: body))
    }
}
