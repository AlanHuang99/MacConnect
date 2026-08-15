import CryptoKit
import Foundation

struct MprisArtworkTransfer: Equatable {
    let player: String
    let url: String
    let data: Data
}

@MainActor
final class LocalMprisService {
    static let fallbackPlayerName = "Mac"
    static let maximumArtworkBytes = 5 * 1024 * 1024

    private let controller: LocalMediaControlling

    init(controller: LocalMediaControlling) {
        self.controller = controller
    }

    func handle(_ packet: NetworkPacket) -> [NetworkPacket] {
        guard packet.type == PacketType.mprisRequest else { return [] }

        if packet.body["requestPlayerList"]?.boolValue == true {
            return [playerListPacket()]
        }

        guard packet.body["player"]?.stringValue == currentPlayerName else {
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
            case "Previous":
                controller.previous()
            case "Next":
                controller.next()
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
        guard snapshot.transportAvailable else { return nil }
        let player = currentPlayerName(for: snapshot)

        var body: [String: AnyJSON] = [
            "player": .string(player),
            "isPlaying": .bool(snapshot.isPlaying),
            "canPlay": .bool(snapshot.transportAvailable),
            "canPause": .bool(snapshot.transportAvailable),
            "canGoNext": .bool(snapshot.transportAvailable),
            "canGoPrevious": .bool(snapshot.transportAvailable),
            "canSeek": .bool(false),
            "volume": .int(Int64(snapshot.volume ?? -1))
        ]

        if let title = snapshot.title { body["title"] = .string(title) }
        if let artist = snapshot.artist { body["artist"] = .string(artist) }
        if let album = snapshot.album { body["album"] = .string(album) }
        if let lengthMs = snapshot.lengthMs { body["length"] = .int(lengthMs) }
        if let positionMs = snapshot.positionMs { body["pos"] = .int(positionMs) }
        if let artwork = artwork(for: snapshot) {
            body["albumArtUrl"] = .string(artwork.url)
        }

        return NetworkPacket(type: PacketType.mpris, body: body)
    }

    func playerListPacket() -> NetworkPacket {
        let players = playerNames.map(AnyJSON.string)
        return NetworkPacket(
            type: PacketType.mpris,
            body: [
                "playerList": .array(players),
                "supportAlbumArtPayload": .bool(true)
            ]
        )
    }

    func artworkTransfer(for packet: NetworkPacket) -> MprisArtworkTransfer? {
        guard packet.type == PacketType.mprisRequest else { return nil }
        let snapshot = controller.snapshot
        let player = currentPlayerName(for: snapshot)
        guard packet.body["player"]?.stringValue == player,
              let requestedURL = packet.body["albumArtUrl"]?.stringValue,
              let artwork = artwork(for: snapshot),
              requestedURL == artwork.url
        else { return nil }
        return MprisArtworkTransfer(player: player, url: artwork.url, data: artwork.data)
    }

    var playerNames: [String] {
        let snapshot = controller.snapshot
        return snapshot.transportAvailable ? [currentPlayerName(for: snapshot)] : []
    }

    private var currentPlayerName: String {
        currentPlayerName(for: controller.snapshot)
    }

    private func currentPlayerName(for snapshot: LocalMediaSnapshot) -> String {
        let trimmed = snapshot.playerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return Self.fallbackPlayerName }
        return trimmed
    }

    private func artwork(for snapshot: LocalMediaSnapshot) -> (url: String, data: Data)? {
        guard snapshot.transportAvailable,
              let data = snapshot.artworkData,
              !data.isEmpty,
              data.count <= Self.maximumArtworkBytes
        else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ("kdeconnect://macconnect/album-art/\(digest)", data)
    }
}
