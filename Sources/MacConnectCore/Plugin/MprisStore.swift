import Foundation
import Combine

/// Observable now-playing state per device. `MprisPlugin` updates the
/// store from incoming `kdeconnect.mpris` packets; the popover UI reads.
@MainActor
public final class MprisStore: ObservableObject {
    public static let shared = MprisStore()

    public struct State: Equatable, Sendable {
        public var player: String
        public var title: String?
        public var artist: String?
        public var album: String?
        public var isPlaying: Bool
        public var canPlay: Bool
        public var canPause: Bool
        public var canGoNext: Bool
        public var canGoPrevious: Bool
        public var volume: Int?
        public var lengthMs: Int64?
        public var positionMs: Int64?

        public init(player: String) {
            self.player = player
            self.title = nil
            self.artist = nil
            self.album = nil
            self.isPlaying = false
            self.canPlay = true
            self.canPause = true
            self.canGoNext = true
            self.canGoPrevious = true
            self.volume = nil
            self.lengthMs = nil
            self.positionMs = nil
        }

        /// Concise one-line description of the current track. `nil` if we
        /// have no track info at all (e.g. peer just sent a player list).
        public var titleLine: String? {
            switch (title, artist) {
            case let (.some(t), .some(a)) where !t.isEmpty && !a.isEmpty:
                return "\(t) — \(a)"
            case let (.some(t), _) where !t.isEmpty:
                return t
            case let (_, .some(a)) where !a.isEmpty:
                return a
            default:
                return nil
            }
        }
    }

    @Published public private(set) var states: [String: State] = [:]

    public init() {}

    public func update(deviceId: String, with packet: NetworkPacket) {
        guard let player = packet.body["player"]?.stringValue, !player.isEmpty else {
            // Some MPRIS packets carry only a `playerList`; treat those as a
            // ping that confirms the plugin is wired without changing state.
            return
        }
        // When the peer switches to a different player (e.g. closed
        // Spotify, opened VLC), KDE Connect can send subsequent updates
        // that omit fields the new player doesn't yet have. Without
        // resetting metadata we'd render the previous player's title on
        // top of the new player's controls. Drop the stale fields when
        // the player identity changes; only the per-field if-let updates
        // below restore them when the packet actually carries the data.
        var state: State
        if let existing = states[deviceId], existing.player == player {
            state = existing
        } else {
            state = State(player: player)
        }
        if let title = packet.body["title"]?.stringValue { state.title = title }
        if let artist = packet.body["artist"]?.stringValue { state.artist = artist }
        if let album = packet.body["album"]?.stringValue { state.album = album }
        // Some KDE Connect peers (older Android builds, certain plugins)
        // still pack track info into a single `nowPlaying` string instead
        // of separate `title`/`artist`. Fall back so the tile isn't blank
        // against peers that use only the deprecated field.
        if state.title == nil, state.artist == nil,
           let nowPlaying = packet.body["nowPlaying"]?.stringValue,
           !nowPlaying.isEmpty {
            state.title = nowPlaying
        }
        if let isPlaying = packet.body["isPlaying"]?.boolValue { state.isPlaying = isPlaying }
        if let canPlay = packet.body["canPlay"]?.boolValue { state.canPlay = canPlay }
        if let canPause = packet.body["canPause"]?.boolValue { state.canPause = canPause }
        if let canGoNext = packet.body["canGoNext"]?.boolValue { state.canGoNext = canGoNext }
        if let canGoPrevious = packet.body["canGoPrevious"]?.boolValue { state.canGoPrevious = canGoPrevious }
        if let volume = packet.body["volume"]?.intValue { state.volume = Int(volume) }
        if let length = packet.body["length"]?.intValue { state.lengthMs = length }
        if let pos = packet.body["pos"]?.intValue { state.positionMs = pos }
        states[deviceId] = state
    }

    /// Process a player-list-only update. If the peer's announced player
    /// set no longer contains the player we cached (e.g. the user closed
    /// the music app), drop the cached state so the UI doesn't keep
    /// targeting a player that doesn't exist any more. Returns the list
    /// so callers can fire per-player nowPlaying requests.
    @discardableResult
    public func applyPlayerList(deviceId: String, players: [String]) -> [String] {
        if let existing = states[deviceId], !players.contains(existing.player) {
            states[deviceId] = nil
        }
        if players.isEmpty {
            states[deviceId] = nil
        }
        return players
    }

    public func state(for deviceId: String) -> State? {
        states[deviceId]
    }

    public func clear(deviceId: String) {
        states[deviceId] = nil
    }
}
