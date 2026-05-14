import Foundation
import NIOCore
import NIOSSL
import NIOTLS

/// Channel handler implementing KDE Connect's plain-TCP-then-TLS protocol.
///
/// Flow:
///   1. **Plain identity exchange.** Newline-framed JSON identity packet over
///      plain TCP. Outbound (we initiated TCP): we write our identity in
///      channelActive. Inbound (we accepted): we read the peer's identity
///      first, then write ours.
///   2. **TLS upgrade with inverted roles.** Per KDE Connect protocol:
///      - The TCP-connect initiator becomes the TLS **server**.
///      - The TCP-accept side becomes the TLS **client**.
///      We install the matching NIOSSLHandler at pipeline position `.first`
///      and replay any buffered bytes through it.
///   3. **Custom verification.** NIOSSL skips system trust; PeerVerifier
///      enforces TOFU on first pair and pinning afterwards.
///   4. **Ready.** Newline-framed JSON packets flow until close.
public final class KDEConnectChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer

    public enum Role {
        case inbound
        case outbound(peerIdentity: IdentityPayload)
    }

    private enum State {
        case awaitingPlainIdentity
        case awaitingTLSHandshake
        case ready
    }

    /// Max bytes we'll buffer in each state before declaring the peer hostile
    /// and closing. The plain-identity bound protects against a peer that
    /// never sends `\n`; the post-handshake bound caps any single control
    /// packet (payload transfers use a separate channel and never get this
    /// large here).
    private static let plainIdentityBufferLimit = 64 * 1024
    private static let readyBufferLimit = 4 * 1024 * 1024
    public static let tlsHandshakeTimeoutSeconds: Int64 = 15

    private let role: Role
    private var state: State = .awaitingPlainIdentity
    private var readBuffer = ByteBuffer()
    /// Bytes already scanned for `\n` since the last consume. We don't
    /// rescan the same prefix every channelRead — small chunked reads on
    /// large packets used to re-walk the buffer each time.
    private var firstLFSearchedBytes: Int = 0
    private var peerDeviceId: String?
    private var peerIdentity: IdentityPayload?
    private var handshakeTimeout: Scheduled<Void>?

    private let sslContext: NIOSSLContext
    private let onIdentity: @Sendable (IdentityPayload, Channel) -> Void
    private let onPacket: @Sendable (NetworkPacket) -> Void
    private let onSecured: @Sendable () -> Void
    private let onClose: @Sendable (Error?) -> Void

    public init(
        role: Role,
        sslContext: NIOSSLContext,
        onIdentity: @escaping @Sendable (IdentityPayload, Channel) -> Void,
        onPacket: @escaping @Sendable (NetworkPacket) -> Void,
        onSecured: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable (Error?) -> Void
    ) {
        self.role = role
        self.sslContext = sslContext
        self.onIdentity = onIdentity
        self.onPacket = onPacket
        self.onSecured = onSecured
        self.onClose = onClose
        if case .outbound(let id) = role {
            self.peerIdentity = id
            self.peerDeviceId = id.deviceId
        }
    }

    public func channelActive(context: ChannelHandlerContext) {
        if case .outbound = role {
            // Send our identity plain, then immediately install TLS server.
            // The remote (TCP-server / TLS-client) will read the plain
            // identity bytes BEFORE its TLS handler is wired, which is correct.
            sendOwnIdentityPlain(context: context)
            installSSLHandlerAndReplay(context: context, isServer: true, leftover: nil)
        }
        context.fireChannelActive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        readBuffer.writeBuffer(&inbound)

        let limit: Int = switch state {
        case .awaitingPlainIdentity, .awaitingTLSHandshake:
            Self.plainIdentityBufferLimit
        case .ready:
            Self.readyBufferLimit
        }
        if readBuffer.readableBytes > limit {
            Log.net
                .error(
                    "Read buffer overflow (\(self.readBuffer.readableBytes, privacy: .public) > \(limit, privacy: .public)) for \(self.peerDeviceId ?? "?", privacy: .public); closing channel"
                )
            context.close(promise: nil)
            return
        }

        switch state {
        case .awaitingPlainIdentity:
            tryParsePlainIdentity(context: context)
        case .awaitingTLSHandshake:
            // Plaintext bytes should not arrive here: the SSL handler sits
            // before us in the pipeline and is the one that decodes incoming
            // bytes during the handshake.
            Log.net.warning("Bytes during TLS handshake state are unexpected")
        case .ready:
            drainReadyPackets()
        }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tls = event as? TLSUserEvent, case .handshakeCompleted = tls {
            Log.net.info("TLS handshake completed for \(self.peerDeviceId ?? "?", privacy: .public)")
            DiagnosticLog.shared.record("net", "tls-complete device=\(peerDeviceId ?? "?")")
            handshakeTimeout?.cancel()
            handshakeTimeout = nil
            state = .ready
            onSecured()
            // Any plaintext bytes already buffered post-handshake (rare) drain now.
            drainReadyPackets()
        }
        if let idle = event as? IdleStateHandler.IdleStateEvent, idle == .read {
            // The IdleStateHandler upstream of us fired a read-timeout. Either
            // the OS-level TCP keepalive has already torn the socket down and
            // we haven't noticed, or the peer is silently wedged. Closing
            // releases the link so the next discovery tick can reconnect.
            Log.net.notice("Read-idle timeout for \(self.peerDeviceId ?? "?", privacy: .public); closing channel")
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log the concrete error case (e.g. "uncleanShutdown") rather than the
        // bridged NSError "operation couldn't be completed" generic. This is
        // crucial for diagnosing post-handshake drops on KDE Connect peers.
        let detail = String(reflecting: error)
        Log.net.error("Channel error \(self.peerDeviceId ?? "?", privacy: .public): \(detail, privacy: .public)")
        DiagnosticLog.shared.record("net", "channel-error device=\(peerDeviceId ?? "?") error=\(detail)")
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        onClose(error)
        context.close(promise: nil)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        onClose(nil)
        context.fireChannelInactive()
    }

    // MARK: - Plain identity parsing

    private func tryParsePlainIdentity(context: ChannelHandlerContext) {
        guard let lfIdx = firstLF(in: readBuffer) else { return }
        let lineLen = lfIdx - readBuffer.readerIndex
        guard let lineSlice = readBuffer.readSlice(length: lineLen),
              readBuffer.readBytes(length: 1) != nil else { return }
        let data = Data(lineSlice.readableBytesView)

        guard let packet = try? NetworkPacket.parse(data),
              let identity = IdentityPayload.from(packet: packet)
        else {
            Log.net.error("Plain-TCP identity parse failed")
            context.close(promise: nil)
            return
        }
        peerIdentity = identity
        peerDeviceId = identity.deviceId
        onIdentity(identity, context.channel)

        switch role {
        case .inbound:
            // Peer identity received; we now act as TLS client. Hand any
            // bytes already buffered past the identity LF back into the
            // pipeline so the SSL handler can decode them.
            let leftover = drainBufferAsByteBuffer()
            installSSLHandlerAndReplay(context: context, isServer: false, leftover: leftover)
        case .outbound:
            // Outbound installs the SSL handler in channelActive; this
            // state is logically unreachable. assertionFailure was a
            // crashing trap in DEBUG and a no-op in Release — close
            // explicitly so a protocol-state regression fails cleanly.
            Log.net
                .error(
                    "Outbound channel reached plain-identity state; closing \(self.peerDeviceId ?? "?", privacy: .public)"
                )
            context.close(promise: nil)
        }
    }

    private func drainBufferAsByteBuffer() -> ByteBuffer? {
        guard readBuffer.readableBytes > 0 else { return nil }
        return readBuffer.readSlice(length: readBuffer.readableBytes)
    }

    // MARK: - TLS install

    private func installSSLHandlerAndReplay(context: ChannelHandlerContext, isServer: Bool, leftover: ByteBuffer?) {
        let verify: NIOSSLCustomVerificationCallback = { [weak self] peerCerts, promise in
            guard let self else { promise.succeed(.failed)
                return
            }
            guard let deviceId = peerDeviceId else {
                Log.pair.error("TLS verify with no peer deviceId")
                promise.succeed(.failed)
                return
            }
            let result = PeerVerifier.verify(deviceId: deviceId, peerCerts: peerCerts)
            switch result {
            case .accepted, .pinnedMatch:
                Log.pair
                    .info(
                        "Peer cert accepted for \(deviceId, privacy: .public) (\(String(describing: result), privacy: .public))"
                    )
                promise.succeed(.certificateVerified)
            case .pinnedMismatch(let fingerprint):
                Log.pair
                    .error(
                        "Peer cert MISMATCH for \(deviceId, privacy: .public) — refusing (presented \(fingerprint, privacy: .public))"
                    )
                Task { @MainActor in
                    DeviceManager.shared.flagPinMismatch(deviceId: deviceId, presentedFingerprint: fingerprint)
                }
                promise.succeed(.failed)
            case .missing:
                Log.pair.error("Peer presented no cert")
                promise.succeed(.failed)
            }
        }

        do {
            let sslHandler: ChannelHandler = if isServer {
                NIOSSLServerHandler(
                    context: sslContext,
                    customVerificationCallback: verify
                )
            } else {
                try NIOSSLClientHandler(
                    context: sslContext,
                    serverHostname: nil,
                    customVerificationCallback: verify
                )
            }
            try context.pipeline.syncOperations.addHandler(sslHandler, position: .first)
            state = .awaitingTLSHandshake
            handshakeTimeout?.cancel()
            let channel = context.channel
            let deviceId = peerDeviceId ?? "?"
            handshakeTimeout = context.eventLoop.scheduleTask(in: .seconds(Self.tlsHandshakeTimeoutSeconds)) { [weak self] in
                guard let self, case .awaitingTLSHandshake = self.state else { return }
                Log.net.notice("TLS handshake timed out for \(deviceId, privacy: .public); closing channel")
                DiagnosticLog.shared.record("net", "tls-timeout device=\(deviceId)")
                channel.close(promise: nil)
            }

            // Replay leftover bytes through the head of the pipeline so SSL
            // can decrypt them.
            if let leftover, leftover.readableBytes > 0 {
                context.channel.pipeline.fireChannelRead(leftover)
            }
        } catch {
            Log.net.error("Failed to install TLS handler: \(error.localizedDescription, privacy: .public)")
            context.close(promise: nil)
        }
    }

    // MARK: - Ready: packet drain

    private func drainReadyPackets() {
        while let lfIdx = firstLF(in: readBuffer) {
            let lineLen = lfIdx - readBuffer.readerIndex
            guard let line = readBuffer.readSlice(length: lineLen),
                  readBuffer.readBytes(length: 1) != nil else { break }
            let data = Data(line.readableBytesView)
            if data.isEmpty { continue }
            do {
                let packet = try NetworkPacket.parse(data)
                onPacket(packet)
            } catch {
                Log.net.error("Bad packet (post-TLS): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Outbound identity write

    private func sendOwnIdentityPlain(context: ChannelHandlerContext) {
        // Include the targetDeviceId/targetProtocolVersion fields per protocol
        let identity = Settings.shared.ownIdentity(tcpPort: nil)
        var packet = identity.toPacket()
        if case .outbound(let peer) = role {
            packet.body["targetDeviceId"] = .string(peer.deviceId)
            packet.body["targetProtocolVersion"] = .int(Int64(peer.protocolVersion))
        }
        guard let data = try? packet.serialized() else { return }
        var buf = context.channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        context.writeAndFlush(NIOAny(buf), promise: nil)
    }

    private func firstLF(in buf: ByteBuffer) -> Int? {
        let totalAvailable = buf.readableBytes
        // If the buffer has shrunk since our last scan (caller consumed
        // bytes), our cursor would over-shoot — reset.
        if firstLFSearchedBytes > totalAvailable {
            firstLFSearchedBytes = 0
        }
        let bytes = buf.readableBytesView
        var i = firstLFSearchedBytes
        while i < totalAvailable {
            if bytes[bytes.startIndex + i] == 0x0A {
                // Reset for the upcoming consume; on the next firstLF
                // call the buffer will be shorter and the prefix-check
                // above resets cleanly anyway, but doing it explicitly
                // makes the invariant obvious.
                firstLFSearchedBytes = 0
                return buf.readerIndex + i
            }
            i += 1
        }
        firstLFSearchedBytes = i
        return nil
    }
}
