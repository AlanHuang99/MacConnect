import Foundation
import Combine

/// Renders the peer's battery state in the device row. KDE Connect
/// Android pushes `kdeconnect.battery` on every state change; we also
/// nudge it with `kdeconnect.battery.request` when the popover opens so
/// the tile isn't blank on first view.
public final class BatteryPlugin: Plugin, @unchecked Sendable {
    public let identifier = "battery"
    public let displayName = "Battery"
    public let incomingCapabilities = [PacketType.battery]
    public let outgoingCapabilities = [PacketType.batteryRequest]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        BatteryStore.shared.update(deviceId: device.id, with: packet)
    }

    @MainActor
    public static func requestUpdate(from device: Device) {
        device.send(NetworkPacket(
            type: PacketType.batteryRequest,
            body: ["request": .bool(true)]
        ))
    }
}

@MainActor
public final class BatteryStore: ObservableObject {
    public static let shared = BatteryStore()

    public struct State: Equatable, Sendable {
        public var currentCharge: Int
        public var isCharging: Bool
        /// KDE Connect sends `1` for low-battery; everything else is "normal".
        public var isLow: Bool
    }

    @Published public private(set) var states: [String: State] = [:]

    public init() {}

    public func update(deviceId: String, with packet: NetworkPacket) {
        let charge = packet.body["currentCharge"]?.intValue.map(Int.init) ?? -1
        guard charge >= 0 else { return }
        let isCharging = packet.body["isCharging"]?.boolValue ?? false
        let thresholdEvent = packet.body["thresholdEvent"]?.intValue ?? 0
        states[deviceId] = State(
            currentCharge: charge,
            isCharging: isCharging,
            isLow: thresholdEvent == 1
        )
    }

    public func state(for deviceId: String) -> State? {
        states[deviceId]
    }
}
