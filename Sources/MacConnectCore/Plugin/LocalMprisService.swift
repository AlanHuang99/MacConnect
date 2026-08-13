import Foundation

@MainActor
final class LocalMprisService {
    static let playerName = "Mac"

    private let controller: LocalMediaControlling

    init(controller: LocalMediaControlling) {
        self.controller = controller
    }

    func handle(_ packet: NetworkPacket) -> [NetworkPacket] {
        guard packet.type == PacketType.mprisRequest else { return [] }

        if packet.body["requestPlayerList"]?.boolValue == true {
            return [playerListPacket()]
        }

        guard packet.body["player"]?.stringValue == Self.playerName else {
            return [playerListPacket()]
        }

        if let action = packet.body["action"]?.stringValue {
            switch action {
            case "Play":
                controller.play()
            case "Pause":
                controller.pause()
            case "PlayPause":
                controller.togglePlayPause()
            default:
                break
            }
        }

        if let requestedVolume = packet.body["setVolume"]?.intValue {
            controller.setVolume(min(100, max(0, Int(requestedVolume))))
        }

        if packet.body["requestNowPlaying"]?.boolValue == true ||
            packet.body["requestVolume"]?.boolValue == true
        {
            return [currentStatePacket() ?? playerListPacket()]
        }

        return []
    }

    func currentStatePacket() -> NetworkPacket? {
        let snapshot = controller.snapshot
        guard snapshot.transportAvailable || snapshot.volume != nil else { return nil }

        var body: [String: AnyJSON] = [
            "player": .string(Self.playerName),
            "isPlaying": .bool(snapshot.isPlaying),
            "canPlay": .bool(snapshot.transportAvailable),
            "canPause": .bool(snapshot.transportAvailable),
            "canGoNext": .bool(false),
            "canGoPrevious": .bool(false),
            "canSeek": .bool(false),
            "volume": .int(Int64(snapshot.volume ?? -1))
        ]

        if let title = snapshot.title { body["title"] = .string(title) }
        if let artist = snapshot.artist { body["artist"] = .string(artist) }
        if let album = snapshot.album { body["album"] = .string(album) }
        if let lengthMs = snapshot.lengthMs { body["length"] = .int(lengthMs) }
        if let positionMs = snapshot.positionMs { body["pos"] = .int(positionMs) }

        return NetworkPacket(type: PacketType.mpris, body: body)
    }

    func playerListPacket() -> NetworkPacket {
        let snapshot = controller.snapshot
        let players: [AnyJSON] = snapshot.transportAvailable || snapshot.volume != nil
            ? [.string(Self.playerName)]
            : []
        return NetworkPacket(
            type: PacketType.mpris,
            body: [
                "playerList": .array(players),
                "supportAlbumArtPayload": .bool(false)
            ]
        )
    }
}
