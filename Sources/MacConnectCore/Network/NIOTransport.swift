import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSL

public final class NIOTransport: @unchecked Sendable {
    public static let shared = NIOTransport()

    public let group: EventLoopGroup
    public let sslContext: NIOSSLContext

    /// macOS-default keepalive (~2 h) is far too long for a portable peer.
    /// Override per-connection so a dead Wi-Fi / sleeping phone is detected
    /// in ~60 s and the link can reconnect on the next discovery tick.
    public static let keepaliveIdleSeconds: Int32 = 30
    public static let keepaliveIntervalSeconds: Int32 = 10
    public static let keepaliveCount: Int32 = 3
    /// Belt-and-braces above OS keepalive: if no bytes (encrypted or app-layer
    /// heartbeat) arrive for this long, close the channel. Set generously
    /// because KDE Connect Android does not yet send any application-layer
    /// traffic on idle links — a short timeout would tear down a healthy
    /// idle phone repeatedly. The OS-level TCP keepalive (60 s detection)
    /// is the primary stale-socket signal; this only catches the rare case
    /// where the OS thinks the connection is alive but the app is wedged.
    public static let readIdleSeconds: Int64 = 300

    private init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        do {
            self.sslContext = try TLSContextBuilder.makeContext()
        } catch {
            // Without a working TLS context the LAN protocol cannot run, so
            // crashing at startup is more useful than continuing in a broken
            // state.
            fatalError("TLS context init failed: \(error.localizedDescription)")
        }
    }

    /// Gracefully shut down the NIO event loops with a hard deadline.
    /// Called from `applicationWillTerminate` so the process actually
    /// exits instead of being kept alive by the event-loop threads.
    public func shutdown(deadline: DispatchTime = .now() + 0.5) {
        let group = DispatchGroup()
        group.enter()
        self.group.shutdownGracefully(queue: .global(qos: .userInitiated)) { error in
            if let error {
                Log.net.notice("NIO shutdown error: \(error.localizedDescription, privacy: .public)")
            }
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            Log.net.notice("NIO shutdownGracefully timed out; exiting anyway")
        }
    }

    /// Bind a TCP listener walking ports `min...max`, returning the bound port.
    public func startListener(
        portRange: ClosedRange<UInt16>,
        onIdentity: @escaping @Sendable (IdentityPayload, Channel) -> Void,
        onPacket: @escaping @Sendable (NetworkPacket, Channel) -> Void,
        onSecured: @escaping @Sendable (Channel) -> Void,
        onClose: @escaping @Sendable (Channel, Error?) -> Void
    ) throws -> (Channel, UInt16) {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                // syncOperations sidesteps the (unavailable) Sendable
                // conformance on IdleStateHandler. The initializer runs on
                // the channel's event loop already, which is what
                // syncOperations requires.
                channel.eventLoop.makeCompletedFuture {
                    let idle = IdleStateHandler(readTimeout: .seconds(Self.readIdleSeconds))
                    let handler = KDEConnectChannelHandler(
                        role: .inbound,
                        sslContext: sslContext,
                        onIdentity: { identity, ch in onIdentity(identity, ch) },
                        onPacket: { packet in onPacket(packet, channel) },
                        onSecured: { onSecured(channel) },
                        onClose: { err in onClose(channel, err) }
                    )
                    try channel.pipeline.syncOperations.addHandler(idle)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(Self.tcpKeepaliveIdle, value: Self.keepaliveIdleSeconds)
            .childChannelOption(Self.tcpKeepaliveInterval, value: Self.keepaliveIntervalSeconds)
            .childChannelOption(Self.tcpKeepaliveCount, value: Self.keepaliveCount)

        for port in portRange {
            do {
                let channel = try bootstrap.bind(host: "0.0.0.0", port: Int(port)).wait()
                return (channel, port)
            } catch {
                continue
            }
        }
        throw NSError(domain: "MacConnect.Net", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "No free TCP port in \(portRange)"])
    }

    public func connect(
        host: String,
        port: UInt16,
        peerIdentity: IdentityPayload,
        onPacket: @escaping @Sendable (NetworkPacket, Channel) -> Void,
        onSecured: @escaping @Sendable (Channel) -> Void,
        onClose: @escaping @Sendable (Channel, Error?) -> Void
    ) -> EventLoopFuture<Channel> {
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let idle = IdleStateHandler(readTimeout: .seconds(Self.readIdleSeconds))
                    let handler = KDEConnectChannelHandler(
                        role: .outbound(peerIdentity: peerIdentity),
                        sslContext: sslContext,
                        onIdentity: { _, _ in /* outbound knows identity already */ },
                        onPacket: { packet in onPacket(packet, channel) },
                        onSecured: { onSecured(channel) },
                        onClose: { err in onClose(channel, err) }
                    )
                    try channel.pipeline.syncOperations.addHandler(idle)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(Self.tcpKeepaliveIdle, value: Self.keepaliveIdleSeconds)
            .channelOption(Self.tcpKeepaliveInterval, value: Self.keepaliveIntervalSeconds)
            .channelOption(Self.tcpKeepaliveCount, value: Self.keepaliveCount)
            .connectTimeout(.seconds(5))

        return bootstrap.connect(host: host, port: Int(port))
    }

    // MARK: - macOS TCP keepalive timing options

    //
    // NIO doesn't ship pre-baked helpers for the TCP_KEEPALIVE family because
    // the option names differ across platforms (Linux: TCP_KEEPIDLE, Darwin:
    // TCP_KEEPALIVE). We hard-wire the Darwin values here — the project
    // targets macOS 13+ so cross-platform parity is not a goal.

    static let tcpKeepaliveIdle: ChannelOptions.Types.SocketOption = .init(
        level: .tcp,
        name: NIOBSDSocket.Option(rawValue: CInt(TCP_KEEPALIVE))
    )
    static let tcpKeepaliveInterval: ChannelOptions.Types.SocketOption = .init(
        level: .tcp,
        name: NIOBSDSocket.Option(rawValue: CInt(TCP_KEEPINTVL))
    )
    static let tcpKeepaliveCount: ChannelOptions.Types.SocketOption = .init(
        level: .tcp,
        name: NIOBSDSocket.Option(rawValue: CInt(TCP_KEEPCNT))
    )
}
