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

    /// Replace the active channel with a newer connection and return the
    /// superseded channel for the caller to close (or `nil` if unchanged).
    /// The old channel is intentionally NOT closed here — see below.
    ///
    /// `_isSecure` is reset to `false` because the new channel has not
    /// completed its TLS handshake yet. Without this reset, `send()`
    /// would happily write to the new channel during the ~50–100 ms
    /// pre-handshake window; NIOSSL would buffer the plaintext and
    /// silently drop it if the new channel never reaches handshake (the
    /// observed cause of intermittent "send file" failures with peers
    /// like the KDE Connect iOS app that cycle TCP every 5 s). The
    /// flag flips back to `true` when LanLinkProvider.handleSecured
    /// fires for the new channel.
    ///
    /// Why the close is deferred to the caller: the caller
    /// (`LanLinkProvider.handleIdentity`) holds `linkLock` while replacing
    /// the channel, and `Channel.close` can run synchronously on the calling
    /// event-loop thread — firing `channelInactive` → `onClose` →
    /// `handleClosed`, which takes that same non-recursive `linkLock`.
    /// Closing inline therefore self-deadlocks the discovery queue. The
    /// caller closes the returned channel only after releasing `linkLock`.
    @discardableResult
    public func replaceChannel(with newChannel: Channel) -> Channel? {
        lock.lock()
        let old = channel
        channel = newChannel
        _isSecure = false
        lock.unlock()
        return old !== newChannel ? old : nil
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
        onCloseCallback()
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
