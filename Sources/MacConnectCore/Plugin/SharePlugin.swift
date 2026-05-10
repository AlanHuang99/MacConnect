import Foundation

public final class SharePlugin: Plugin, @unchecked Sendable {
    public let identifier = "share"
    public let displayName = "Share"
    public let incomingCapabilities = [PacketType.shareRequest]
    public let outgoingCapabilities = [PacketType.shareRequest]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        // TODO: handle payloadTransferInfo + open second TLS connection
        // for the file payload. See LanLinkProvider TLS milestone.
        if let url = packet.body["url"]?.stringValue {
            let name = device.name
            Log.plugin.info("Share URL from \(name, privacy: .public): \(url, privacy: .public)")
            await Notifier.show(title: "URL from \(name)", body: url)
        }
    }
}
