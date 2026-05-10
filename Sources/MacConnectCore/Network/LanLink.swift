import Foundation
import NIOCore

public final class LanLink: @unchecked Sendable {
    public let deviceId: String
    public var isSecure: Bool = false

    /// The currently-active channel. Replaced (and the prior channel closed)
    /// when a newer secured connection arrives for the same `deviceId`,
    /// matching KDE Connect's behavior of preferring the most recent socket.
    private var channel: Channel
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

    public var activeChannel: Channel { channel }

    public func replaceChannel(with newChannel: Channel) {
        let old = channel
        channel = newChannel
        if old !== newChannel {
            old.close(promise: nil)
        }
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
            let ch = channel
            var buf = ch.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            let promise = ch.eventLoop.makePromise(of: Void.self)
            ch.writeAndFlush(buf, promise: promise)
            let deviceId = self.deviceId
            let type = packet.type
            promise.futureResult.whenComplete { result in
                switch result {
                case .success:
                    Log.net.debug("Sent \(type, privacy: .public) to \(deviceId, privacy: .public)")
                case .failure(let err):
                    Log.net.error("Write failed for \(type, privacy: .public) to \(deviceId, privacy: .public): \(err.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Log.net.error("Serialize failed for \(packet.type, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
