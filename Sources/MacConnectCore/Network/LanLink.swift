import Foundation
import NIOCore

public final class LanLink: @unchecked Sendable {
    public let deviceId: String

    private let lock = NSLock()
    private var _isSecure: Bool = false
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

    deinit {
#if DEBUG
        Log.net.debug("LanLink deinit: \(self.deviceId, privacy: .public)")
#endif
    }

    public var isSecure: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _isSecure
        }
        set {
            lock.lock()
            _isSecure = newValue
            lock.unlock()
        }
    }

    public var activeChannel: Channel {
        lock.lock(); defer { lock.unlock() }
        return channel
    }

    /// Replace the active channel with a newer secured connection. The old
    /// channel is closed; the new one becomes the send target.
    public func replaceChannel(with newChannel: Channel) {
        lock.lock()
        let old = channel
        channel = newChannel
        lock.unlock()
        if old !== newChannel {
            old.close(promise: nil)
        }
    }

    public func deliverPacket(_ packet: NetworkPacket) {
        // Defence in depth: a peer (e.g. a future MacConnect build) may
        // still send `_keepalive: true` pings; drop them before plugin
        // dispatch so they never raise a banner. We no longer emit them
        // ourselves — see `NetworkPacket.keepalive()` for history.
        if packet.type == PacketType.ping,
           packet.body[NetworkPacket.keepaliveBodyKey]?.boolValue == true {
            Log.net.debug("Received keepalive from \(self.deviceId, privacy: .public); dropping")
            return
        }
        onPacketCallback(packet)
    }

    public func notifyClosed() {
        onCloseCallback()
    }

    public func disconnect() {
        activeChannel.close(promise: nil)
    }

    public func send(_ packet: NetworkPacket) {
        let secure: Bool
        let ch: Channel
        lock.lock()
        secure = _isSecure
        ch = channel
        lock.unlock()

        guard secure else {
            Log.net.warning("Refusing to send \(packet.type, privacy: .public) before TLS for \(self.deviceId, privacy: .public)")
            return
        }
        do {
            let data = try packet.serialized()
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
