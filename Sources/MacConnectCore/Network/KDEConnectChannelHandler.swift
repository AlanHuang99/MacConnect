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

    private let role: Role
    private var state: State = .awaitingPlainIdentity
    private var readBuffer = ByteBuffer()
    private var peerDeviceId: String?
    private var peerIdentity: IdentityPayload?

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
        onClose(error)
        context.close(promise: nil)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        onClose(nil)
        context.fireChannelInactive()
    }

    // MARK: - Plain identity parsing

    private func tryParsePlainIdentity(context: ChannelHandlerContext) {
        guard let lfIdx = firstLF(in: readBuffer) else { return }
        let lineLen = lfIdx - readBuffer.readerIndex
        guard let lineSlice = readBuffer.readSlice(length: lineLen),
              let _ = readBuffer.readBytes(length: 1) else { return }
        let data = Data(lineSlice.readableBytesView)

        guard let packet = try? NetworkPacket.parse(data),
              let identity = IdentityPayload.from(packet: packet) else {
            Log.net.error("Plain-TCP identity parse failed")
            context.close(promise: nil)
            return
        }
        self.peerIdentity = identity
        self.peerDeviceId = identity.deviceId
        onIdentity(identity, context.channel)

        switch role {
        case .inbound:
            // Peer identity received; we now act as TLS client. Hand any
            // bytes already buffered past the identity LF back into the
            // pipeline so the SSL handler can decode them.
            let leftover = drainBufferAsByteBuffer()
            installSSLHandlerAndReplay(context: context, isServer: false, leftover: leftover)
        case .outbound:
            // Outbound installs the SSL handler in channelActive; this state
            // is unreachable for that role.
            assertionFailure("Outbound role parsed plain identity post-TLS install")
        }
    }

    private func drainBufferAsByteBuffer() -> ByteBuffer? {
        guard readBuffer.readableBytes > 0 else { return nil }
        let slice = readBuffer.readSlice(length: readBuffer.readableBytes)
        return slice
    }

    // MARK: - TLS install

    private func installSSLHandlerAndReplay(context: ChannelHandlerContext, isServer: Bool, leftover: ByteBuffer?) {
        let verify: NIOSSLCustomVerificationCallback = { [weak self] peerCerts, promise in
            guard let self else { promise.succeed(.failed); return }
            guard let deviceId = self.peerDeviceId else {
                Log.pair.error("TLS verify with no peer deviceId")
                promise.succeed(.failed)
                return
            }
            let result = PeerVerifier.verify(deviceId: deviceId, peerCerts: peerCerts)
            switch result {
            case .accepted, .pinnedMatch:
                Log.pair.info("Peer cert accepted for \(deviceId, privacy: .public) (\(String(describing: result), privacy: .public))")
                promise.succeed(.certificateVerified)
            case .pinnedMismatch:
                Log.pair.error("Peer cert MISMATCH for \(deviceId, privacy: .public) — refusing")
                Task { @MainActor in
                    DeviceManager.shared.flagPinMismatch(deviceId: deviceId)
                }
                promise.succeed(.failed)
            case .missing:
                Log.pair.error("Peer presented no cert")
                promise.succeed(.failed)
            }
        }

        do {
            let sslHandler: ChannelHandler
            if isServer {
                sslHandler = NIOSSLServerHandler(
                    context: sslContext,
                    customVerificationCallback: verify
                )
            } else {
                sslHandler = try NIOSSLClientHandler(
                    context: sslContext,
                    serverHostname: nil,
                    customVerificationCallback: verify
                )
            }
            try context.pipeline.syncOperations.addHandler(sslHandler, position: .first)
            state = .awaitingTLSHandshake

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
                  let _ = readBuffer.readBytes(length: 1) else { break }
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
        let bytes = buf.readableBytesView
        for (i, b) in bytes.enumerated() where b == 0x0A {
            return buf.readerIndex + i
        }
        return nil
    }
}
