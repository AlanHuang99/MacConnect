import Foundation
import NIOCore
import NIOPosix
import NIOSSL

public final class NIOTransport: @unchecked Sendable {
    public static let shared = NIOTransport()

    public let group: EventLoopGroup
    public let sslContext: NIOSSLContext

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
                let handler = KDEConnectChannelHandler(
                    role: .inbound,
                    sslContext: sslContext,
                    onIdentity: { identity, ch in onIdentity(identity, ch) },
                    onPacket: { packet in onPacket(packet, channel) },
                    onSecured: { onSecured(channel) },
                    onClose: { err in onClose(channel, err) }
                )
                return channel.pipeline.addHandler(handler)
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)

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
                let handler = KDEConnectChannelHandler(
                    role: .outbound(peerIdentity: peerIdentity),
                    sslContext: sslContext,
                    onIdentity: { _, _ in /* outbound knows identity already */ },
                    onPacket: { packet in onPacket(packet, channel) },
                    onSecured: { onSecured(channel) },
                    onClose: { err in onClose(channel, err) }
                )
                return channel.pipeline.addHandler(handler)
            }
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .connectTimeout(.seconds(5))

        return bootstrap.connect(host: host, port: Int(port))
    }
}
