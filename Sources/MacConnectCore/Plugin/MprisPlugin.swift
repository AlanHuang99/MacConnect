import Foundation

public final class MprisPlugin: Plugin, @unchecked Sendable {
    public let identifier = "mpris"
    public let displayName = "Media Control"
    public let incomingCapabilities = [PacketType.mpris]
    public let outgoingCapabilities = [PacketType.mprisRequest]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        // Two protocol shapes overlap here. A "playerList" packet announces
        // available players (peer opened or closed a music app). A "player"
        // packet carries track/state for one player. They can occur
        // together or independently.
        if let playerListArray = packet.body["playerList"]?.arrayValue {
            let players = playerListArray.compactMap(\.stringValue)
            MprisStore.shared.applyPlayerList(deviceId: device.id, players: players)
            // Fan out per-player nowPlaying requests; KDE Connect peers
            // short-circuit nowPlaying lookups that omit the player field
            // and return only the player list. Re-asking with the player
            // populated is what actually fills the tile on first open.
            for playerName in players {
                device.send(NetworkPacket(
                    type: PacketType.mprisRequest,
                    body: [
                        "requestNowPlaying": .bool(true),
                        "player": .string(playerName),
                    ]
                ))
            }
        }
        MprisStore.shared.update(deviceId: device.id, with: packet)
    }

    /// Ask the peer to enumerate its players. We never request now-playing
    /// here directly because KDE Connect peers ignore nowPlaying requests
    /// that don't name a player — they reply with `playerList` only.
    /// Our `handle` method picks that up and follows up with per-player
    /// nowPlaying requests, so the first round trip is List → per-player
    /// requests → per-player state.
    @MainActor
    public static func requestNowPlaying(from device: Device) {
        device.send(NetworkPacket(
            type: PacketType.mprisRequest,
            body: ["requestPlayerList": .bool(true)]
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
