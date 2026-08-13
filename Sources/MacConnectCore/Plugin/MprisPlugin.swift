import Foundation

public final class MprisPlugin: Plugin, @unchecked Sendable {
    public let identifier = "mpris"
    public let displayName = "Media Control"
    public let incomingCapabilities = [PacketType.mpris, PacketType.mprisRequest]
    public let outgoingCapabilities = [PacketType.mprisRequest, PacketType.mpris]

    private let localService: LocalMprisService
    private let devices: @MainActor () -> [Device]
    private let pluginEnabled: @MainActor (String) -> Bool
    private let sendPacket: @MainActor (NetworkPacket, Device) -> Void

    @MainActor
    public convenience init() {
        self.init(
            localController: SystemLocalMediaController(),
            devices: { DeviceManager.shared.deviceList() },
            pluginEnabled: { Settings.shared.isPluginEnabled("mpris", forDevice: $0) },
            sendPacket: { packet, device in device.send(packet) }
        )
    }

    @MainActor
    init(
        localController: LocalMediaControlling,
        devices: @escaping @MainActor () -> [Device],
        pluginEnabled: @escaping @MainActor (String) -> Bool,
        sendPacket: @escaping @MainActor (NetworkPacket, Device) -> Void
    ) {
        self.localService = LocalMprisService(controller: localController)
        self.devices = devices
        self.pluginEnabled = pluginEnabled
        self.sendPacket = sendPacket
        localController.onStateChange = { [weak self] in
            self?.broadcastLocalState()
        }
    }

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        if packet.type == PacketType.mprisRequest {
            for response in localService.handle(packet) {
                sendPacket(response, device)
            }
            return
        }

        guard packet.type == PacketType.mpris else { return }

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
                sendPacket(NetworkPacket(
                    type: PacketType.mprisRequest,
                    body: [
                        "requestNowPlaying": .bool(true),
                        "requestVolume": .bool(true),
                        "player": .string(playerName)
                    ]
                ), device)
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
    public static func setVolume(_ percent: Int, for device: Device) {
        guard let player = MprisStore.shared.state(for: device.id)?.player else { return }
        device.send(volumePacket(player: player, percent: percent))
    }

    nonisolated static func volumePacket(player: String, percent: Int) -> NetworkPacket {
        NetworkPacket(type: PacketType.mprisRequest, body: [
            "player": .string(player),
            "setVolume": .int(Int64(min(100, max(0, percent))))
        ])
    }

    @MainActor
    private static func sendAction(_ device: Device, _ action: String) {
        var body: [String: AnyJSON] = ["action": .string(action)]
        if let player = MprisStore.shared.state(for: device.id)?.player {
            body["player"] = .string(player)
        }
        device.send(NetworkPacket(type: PacketType.mprisRequest, body: body))
    }

    @MainActor
    private func broadcastLocalState() {
        let packet = localService.currentStatePacket() ?? localService.playerListPacket()
        for device in devices() where Self.canReceiveLocalState(
            device: device,
            pluginEnabled: pluginEnabled(device.id)
        ) {
            sendPacket(packet, device)
        }
    }

    @MainActor
    private static func canReceiveLocalState(device: Device, pluginEnabled: Bool) -> Bool {
        device.isPaired &&
            device.isReachable &&
            pluginEnabled &&
            device.incomingCapabilities.contains(PacketType.mpris)
    }
}
