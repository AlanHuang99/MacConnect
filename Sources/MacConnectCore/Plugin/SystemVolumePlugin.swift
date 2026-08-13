import Foundation

/// Exposes the Mac's current default output in KDE Connect Android's
/// Multimedia control > Devices tab. KDE's protocol supports many sinks, but
/// one stable sink is sufficient here because Core Audio already follows the
/// system default output when it changes.
public final class SystemVolumePlugin: Plugin, @unchecked Sendable {
    public let identifier = "systemvolume"
    public let displayName = "System Volume"
    public let incomingCapabilities = [PacketType.systemVolumeRequest]
    public let outgoingCapabilities = [PacketType.systemVolume]

    private static let sinkName = "default-output"

    private let volumeProvider: SystemVolumeProviding
    private let devices: @MainActor () -> [Device]
    private let pluginEnabled: @MainActor (String) -> Bool
    private let sendPacket: @MainActor (NetworkPacket, Device) -> Void

    @MainActor
    public convenience init() {
        self.init(
            volumeProvider: CoreAudioVolumeController(),
            devices: { DeviceManager.shared.deviceList() },
            pluginEnabled: { Settings.shared.isPluginEnabled("systemvolume", forDevice: $0) },
            sendPacket: { packet, device in device.send(packet) }
        )
    }

    @MainActor
    init(
        volumeProvider: SystemVolumeProviding,
        devices: @escaping @MainActor () -> [Device],
        pluginEnabled: @escaping @MainActor (String) -> Bool,
        sendPacket: @escaping @MainActor (NetworkPacket, Device) -> Void
    ) {
        self.volumeProvider = volumeProvider
        self.devices = devices
        self.pluginEnabled = pluginEnabled
        self.sendPacket = sendPacket
        volumeProvider.onChange = { [weak self] in self?.broadcastCurrentState() }
    }

    @MainActor
    public func attach(to device: Device) async {
        guard canReceiveState(device) else { return }
        sendPacket(sinkListPacket(), device)
    }

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        guard packet.type == PacketType.systemVolumeRequest else { return }

        if packet.body["requestSinks"]?.boolValue == true {
            sendPacket(sinkListPacket(), device)
        }

        guard packet.body["name"]?.stringValue == Self.sinkName else { return }
        if let requestedVolume = packet.body["volume"]?.intValue {
            volumeProvider.setVolume(Int(min(100, max(0, requestedVolume))))
        }
        if let requestedMute = packet.body["muted"]?.boolValue {
            volumeProvider.setMuted(requestedMute)
        }
    }

    @MainActor
    private func sinkListPacket() -> NetworkPacket {
        NetworkPacket(type: PacketType.systemVolume, body: [
            "sinkList": .array([.dictionary(currentSinkBody())])
        ])
    }

    @MainActor
    private func statePacket() -> NetworkPacket {
        NetworkPacket(type: PacketType.systemVolume, body: currentSinkBody())
    }

    @MainActor
    private func currentSinkBody() -> [String: AnyJSON] {
        [
            "name": .string(Self.sinkName),
            "description": .string("Mac Output"),
            "volume": .int(Int64(volumeProvider.volume ?? 0)),
            "maxVolume": .int(100),
            "muted": .bool(volumeProvider.isMuted ?? false),
            "enabled": .bool(true)
        ]
    }

    @MainActor
    private func broadcastCurrentState() {
        let packet = statePacket()
        for device in devices() where canReceiveState(device) {
            sendPacket(packet, device)
        }
    }

    @MainActor
    private func canReceiveState(_ device: Device) -> Bool {
        device.isPaired &&
            device.isReachable &&
            pluginEnabled(device.id) &&
            device.incomingCapabilities.contains(PacketType.systemVolume)
    }
}
