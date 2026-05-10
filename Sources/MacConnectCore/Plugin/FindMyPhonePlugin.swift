import Foundation

public final class FindMyPhonePlugin: Plugin, @unchecked Sendable {
    public let identifier = "findmyphone"
    public let displayName = "Find My Phone"
    public let incomingCapabilities: [String] = []
    public let outgoingCapabilities = [PacketType.findMyPhoneRequest]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {}

    @MainActor
    public static func ring(_ device: Device) {
        device.send(NetworkPacket(type: PacketType.findMyPhoneRequest))
    }
}
