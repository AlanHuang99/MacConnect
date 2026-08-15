import Foundation
import NIOCore

public final class LanLink: @unchecked Sendable {
    public let deviceId: String

    private let lock = NSLock()
    private var _isSecure: Bool = false
    private var channel: Channel
    private let onPacketCallback: @Sendable (NetworkPacket) -> Void
    private let onCloseCallback: @Sendable (LanLink) -> Void

    public init(
        deviceId: String,
        channel: Channel,
        onPacket: @escaping @Sendable (NetworkPacket) -> Void,
        onClose: @escaping @Sendable (LanLink) -> Void
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
            lock.lock()
            defer { lock.unlock() }
            return _isSecure
        }
        set {
            lock.lock()
            _isSecure = newValue
            lock.unlock()
        }
    }

    public var activeChannel: Channel {
        lock.lock()
        defer { lock.unlock() }
        return channel
    }

    /// Mark `candidate` secure only if it is still this link's active channel.
    /// A late TLS callback from a superseded channel must not mutate the link.
    @discardableResult
    public func markSecured(channel candidate: Channel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard channel === candidate else { return false }
        _isSecure = true
        return true
    }

    /// Atomically promote an already-secured candidate and return the
    /// superseded active channel for deferred closure by the provider.
    ///
    /// The candidate is never installed before TLS completes, so concurrent
    /// sends continue using the old secure channel throughout the handshake.
    /// The returned channel is intentionally left open: the provider holds its
    /// own state lock while calling this method, and a synchronous close can
    /// re-enter the provider through `channelInactive`.
    @discardableResult
    public func promoteSecuredChannel(_ candidate: Channel) -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        let previous = channel
        channel = candidate
        _isSecure = true
        return previous === candidate ? nil : previous
    }

    /// Replace an incumbent that cannot carry secure traffic and reset the
    /// link to its pre-TLS state. The provider removes the old channel's map
    /// entry under its generation lock, then closes the returned channel only
    /// after releasing that lock.
    @discardableResult
    public func replaceChannelBeforeTLS(_ candidate: Channel) -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        let previous = channel
        channel = candidate
        _isSecure = false
        return previous === candidate ? nil : previous
    }

    public func deliverPacket(_ packet: NetworkPacket) {
        // Defence in depth: a peer (e.g. a future MacConnect build) may
        // still send `_keepalive: true` pings; drop them before plugin
        // dispatch so they never raise a banner. We no longer emit them
        // ourselves — see `NetworkPacket.keepalive()` for history.
        if packet.type == PacketType.ping,
           packet.body[NetworkPacket.keepaliveBodyKey]?.boolValue == true
        {
            Log.net.debug("Received keepalive from \(self.deviceId, privacy: .public); dropping")
            return
        }
        onPacketCallback(packet)
    }

    public func notifyClosed() {
        onCloseCallback(self)
    }

    public func disconnect() {
        activeChannel.close(promise: nil)
    }

    /// Hand the packet to NIO. Returns `true` if the link was secure
    /// AND the write was issued (the actual flush is observed
    /// asynchronously and logged); returns `false` if the link wasn't
    /// secure or serialization failed, so callers can fail fast instead
    /// of waiting on a downstream timeout.
    @discardableResult
    public func send(_ packet: NetworkPacket) -> Bool {
        let secure: Bool
        let ch: Channel
        lock.lock()
        secure = _isSecure
        ch = channel
        lock.unlock()

        guard secure else {
            Log.net
                .warning(
                    "Refusing to send \(packet.type, privacy: .public) before TLS for \(self.deviceId, privacy: .public)"
                )
            return false
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
                    Log.net
                        .error(
                            "Write failed for \(type, privacy: .public) to \(deviceId, privacy: .public): \(err.localizedDescription, privacy: .public)"
                        )
                }
            }
            return true
        } catch {
            Log.net
                .error(
                    "Serialize failed for \(packet.type, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            return false
        }
    }
}
