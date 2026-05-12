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
        var state = states[deviceId] ?? State(player: player)
        state.player = player
        if let title = packet.body["title"]?.stringValue { state.title = title }
        if let artist = packet.body["artist"]?.stringValue { state.artist = artist }
        if let album = packet.body["album"]?.stringValue { state.album = album }
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

    public func state(for deviceId: String) -> State? {
        states[deviceId]
    }

    public func clear(deviceId: String) {
        states[deviceId] = nil
    }
}
