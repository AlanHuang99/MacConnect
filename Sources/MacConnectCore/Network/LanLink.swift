import Foundation
import NIOCore

public final class LanLink: @unchecked Sendable {
    public let deviceId: String
    public var isSecure: Bool = false

    private let channel: Channel
    private let onPacketCallback: @Sendable (NetworkPacket) -> Void
    private let onCloseCallback: @Sendable () -> Void

    public init(
        deviceId: String,
        channel: Channel,
        onPacket: @escaping @Sendable (NetworkPacket) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.deviceId = deviceId
        self.channel = channel
        self.onPacketCallback = onPacket
        self.onCloseCallback = onClose
    }

    public func deliverPacket(_ packet: NetworkPacket) {
        onPacketCallback(packet)
    }

    public func notifyClosed() {
        onCloseCallback()
    }

    public func disconnect() {
        channel.close(promise: nil)
    }

    public func send(_ packet: NetworkPacket) {
        guard isSecure else {
            Log.net.warning("Refusing to send \(packet.type, privacy: .public) before TLS for \(self.deviceId, privacy: .public)")
            return
        }
        do {
            let data = try packet.serialized()
            var buf = channel.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            channel.writeAndFlush(buf, promise: nil)
        } catch {
            Log.net.error("Serialize failed for \(packet.type, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
