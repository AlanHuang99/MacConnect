import Combine
import Foundation

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
    /// Peer presented a cert that does not match our pinned one. Until the
    /// user resets trust, TLS handshakes with this peer will keep failing.
    @Published public var pinMismatch: Bool = false
    /// SHA-256 of the cert the peer just presented (colon-grouped hex).
    /// Populated when `pinMismatch` flips true so the UI can show the user
    /// what changed — the pre-existing pinned fingerprint comes from
    /// `CertificateService.fingerprint(forTrustedDeviceId:)`.
    @Published public var presentedFingerprint: String?
    @Published public var lastSeen: Date = .init()

    public var protocolVersion: Int
    public var incomingCapabilities: [String]
    public var outgoingCapabilities: [String]

    /// Strong reference to the active link for this device. `LanLinkProvider`
    /// also holds the link by deviceId; both owners drop their references
    /// together when `DeviceManager.detach` runs on a `handleClosed`
    /// notification. A previous `weak` here meant the link could go nil
    /// between provider-cleanup and device-row read, surfacing as
    /// "device shows online but sends do nothing".
    var link: LanLink?

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
        name = identity.deviceName
        type = identity.deviceType
        protocolVersion = identity.protocolVersion
        incomingCapabilities = identity.incomingCapabilities
        outgoingCapabilities = identity.outgoingCapabilities
        lastSeen = Date()
    }

    /// Send the packet via the active link. Returns `true` only if the
    /// link exists AND was secure AND the write was issued. Callers
    /// like `SharePlugin.sendFile` use the return value to fail their
    /// transfer immediately instead of waiting on a 60 s receiver
    /// timeout when the channel is mid-replace or unsecured.
    @discardableResult
    public func send(_ packet: NetworkPacket) -> Bool {
        guard let link else {
            Log.net
                .warning(
                    "Device \(self.id, privacy: .public) has no link; dropping packet \(packet.type, privacy: .public)"
                )
            DiagnosticLog.shared.record("send", "refused packet=\(packet.type) device=\(id) reason=no-link")
            return false
        }
        return link.send(packet)
    }

    @discardableResult
    public func sendUserCommand(
        _ packet: NetworkPacket,
        failureMessage: String,
        failureDetail: String? = "Device not ready"
    ) -> Bool {
        let sent = send(packet)
        if !sent {
            Log.plugin.notice("Command \(packet.type, privacy: .public) not sent to \(self.id, privacy: .public)")
            TransferStore.shared.publishCommandFailure(message: failureMessage, detail: failureDetail)
        }
        return sent
    }
}
