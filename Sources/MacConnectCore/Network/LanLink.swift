import Foundation
import NIOCore

public final class LanLink: @unchecked Sendable {
    public let deviceId: String

    /// How often to send `_keepalive` pings on a secured link. Short enough to
    /// keep typical Wi-Fi NAT mappings warm; long enough not to dominate the
    /// link's traffic.
    public static let heartbeatInterval: TimeAmount = .seconds(30)

    private let lock = NSLock()
    private var _isSecure: Bool = false
    private var channel: Channel
    private let onPacketCallback: @Sendable (NetworkPacket) -> Void
    private let onCloseCallback: @Sendable () -> Void
    private var heartbeatTask: RepeatedTask?
    private var lastPacketReceivedTime: Date = Date()

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
        // Belt-and-braces: tasks are also cancelled in notifyClosed, but if a
        // link is dropped without that path running (e.g. test teardown) the
        // scheduled task would keep firing on the event loop.
        heartbeatTask?.cancel()
    }

    public var isSecure: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _isSecure
        }
        set {
            let wasSecure: Bool
            lock.lock()
            wasSecure = _isSecure
            _isSecure = newValue
            lock.unlock()
            if newValue, !wasSecure {
                startHeartbeat()
            }
        }
    }

    public var activeChannel: Channel {
        lock.lock(); defer { lock.unlock() }
        return channel
    }

    /// Most recent moment we observed an inbound packet (any kind) on this
    /// link. Used by the heartbeat as an application-layer liveness check.
    public var lastPacketReceived: Date {
        lock.lock(); defer { lock.unlock() }
        return lastPacketReceivedTime
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
        lock.lock()
        lastPacketReceivedTime = Date()
        lock.unlock()
        // Drop heartbeat pings before user-visible plugin dispatch — they
        // exist solely to keep the link warm. The peer might send them with
        // an absent message body too; either way they're not for the UI.
        if packet.type == PacketType.ping,
           packet.body[NetworkPacket.keepaliveBodyKey]?.boolValue == true {
            Log.net.debug("Received keepalive from \(self.deviceId, privacy: .public)")
            return
        }
        onPacketCallback(packet)
    }

    public func notifyClosed() {
        lock.lock()
        let task = heartbeatTask
        heartbeatTask = nil
        lock.unlock()
        task?.cancel()
        onCloseCallback()
    }

    public func disconnect() {
        activeChannel.close(promise: nil)
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let channel = activeChannel
        // Bind to a let so the closure doesn't capture self.
        let deviceId = self.deviceId
        let task = channel.eventLoop.scheduleRepeatedTask(
            initialDelay: Self.heartbeatInterval,
            delay: Self.heartbeatInterval
        ) { [weak self] task in
            guard let self else { task.cancel(); return }
            guard self.isSecure, self.activeChannel.isActive else {
                task.cancel()
                return
            }
            Log.net.debug("Sending keepalive to \(deviceId, privacy: .public)")
            self.send(NetworkPacket.keepalive())
        }
        lock.lock()
        heartbeatTask?.cancel()
        heartbeatTask = task
        lock.unlock()
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
