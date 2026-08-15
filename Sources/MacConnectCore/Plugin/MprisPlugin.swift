import Foundation

public final class MprisPlugin: Plugin, @unchecked Sendable {
    public let identifier = "mpris"
    public let displayName = "Media Control"
    public let incomingCapabilities = [PacketType.mprisRequest]
    public let outgoingCapabilities = [PacketType.mpris]

    private let localService: LocalMprisService
    private let devices: @MainActor () -> [Device]
    private let pluginEnabled: @MainActor (String) -> Bool
    private let sendPacket: @MainActor (NetworkPacket, Device) -> Void
    private let sendArtwork: @MainActor (MprisArtworkTransfer, Device) -> Void
    private var lastBroadcastPlayers: [String]

    @MainActor
    public convenience init() {
        let artworkSender = MprisArtworkPayloadSender()
        self.init(
            localController: SystemLocalMediaController(),
            devices: { DeviceManager.shared.deviceList() },
            pluginEnabled: { Settings.shared.isPluginEnabled("mpris", forDevice: $0) },
            sendPacket: { packet, device in device.send(packet) },
            sendArtwork: artworkSender.send
        )
    }

    @MainActor
    init(
        localController: LocalMediaControlling,
        devices: @escaping @MainActor () -> [Device],
        pluginEnabled: @escaping @MainActor (String) -> Bool,
        sendPacket: @escaping @MainActor (NetworkPacket, Device) -> Void,
        sendArtwork: @escaping @MainActor (MprisArtworkTransfer, Device) -> Void = { _, _ in }
    ) {
        self.localService = LocalMprisService(controller: localController)
        self.devices = devices
        self.pluginEnabled = pluginEnabled
        self.sendPacket = sendPacket
        self.sendArtwork = sendArtwork
        self.lastBroadcastPlayers = localService.playerNames
        localController.onStateChange = { [weak self] in
            self?.broadcastLocalState()
        }
    }

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        if packet.type == PacketType.mprisRequest {
            if let transfer = localService.artworkTransfer(for: packet) {
                sendArtwork(transfer, device)
                return
            }
            for response in localService.handle(packet) {
                sendPacket(response, device)
            }
        }
    }

    @MainActor
    public func attach(to device: Device) async {
        guard Self.canReceiveLocalState(
            device: device,
            pluginEnabled: pluginEnabled(device.id)
        ) else { return }
        sendPacket(localService.playerListPacket(), device)
        if let statePacket = localService.currentStatePacket() {
            sendPacket(statePacket, device)
        }
    }

    @MainActor
    private func broadcastLocalState() {
        let statePacket = localService.currentStatePacket()
        let players = localService.playerNames
        let playerListChanged = players != lastBroadcastPlayers
        lastBroadcastPlayers = players
        for device in devices() where Self.canReceiveLocalState(
            device: device,
            pluginEnabled: pluginEnabled(device.id)
        ) {
            if playerListChanged || statePacket == nil {
                sendPacket(localService.playerListPacket(), device)
            }
            if let statePacket {
                sendPacket(statePacket, device)
            }
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
