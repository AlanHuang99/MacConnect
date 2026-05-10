import Foundation
import Combine

@MainActor
public final class Device: ObservableObject, Identifiable {
    public let id: String
    @Published public var name: String
    @Published public var type: DeviceType
    @Published public var isReachable: Bool = false
    @Published public var isPaired: Bool
    /// Peer asked us to pair; we need user input.
    @Published public var incomingPairRequest: Bool = false
    /// We asked peer to pair; we're waiting for their response.
    @Published public var outgoingPairRequest: Bool = false
    @Published public var lastSeen: Date = Date()

    public var protocolVersion: Int
    public var incomingCapabilities: [String]
    public var outgoingCapabilities: [String]

    weak var link: LanLink?

    public init(identity: IdentityPayload, paired: Bool) {
        self.id = identity.deviceId
        self.name = identity.deviceName
        self.type = identity.deviceType
        self.protocolVersion = identity.protocolVersion
        self.incomingCapabilities = identity.incomingCapabilities
        self.outgoingCapabilities = identity.outgoingCapabilities
        self.isPaired = paired
    }

    public func update(from identity: IdentityPayload) {
        self.name = identity.deviceName
        self.type = identity.deviceType
        self.protocolVersion = identity.protocolVersion
        self.incomingCapabilities = identity.incomingCapabilities
        self.outgoingCapabilities = identity.outgoingCapabilities
        self.lastSeen = Date()
    }

    public func send(_ packet: NetworkPacket) {
        guard let link else {
            Log.net.warning("Device \(self.id, privacy: .public) has no link; dropping packet \(packet.type, privacy: .public)")
            return
        }
        link.send(packet)
    }
}
