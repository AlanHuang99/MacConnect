import Foundation
import Network
import NIOCore
import Darwin

/// Owns UDP discovery + TCP server. Discovers peers and creates secure links.
///
/// Discovery is via UDP broadcast (subnet-directed + 255.255.255.255) on port
/// 1716. Each link's plain-TCP-then-TLS handshake is implemented in
/// ``KDEConnectChannelHandler``.
public final class LanLinkProvider: @unchecked Sendable {
    public static let shared = LanLinkProvider()

    private let queue = DispatchQueue(label: "macconnect.lanprovider")
    private var udpListener: NWListener?
    private var serverChannel: Channel?
    private var tcpPort: UInt16 = Settings.minTCPPort
    private var broadcastTimer: DispatchSourceTimer?
    private let linkLock = NSLock()
    private var channelToDeviceId: [ObjectIdentifier: String] = [:]
    private var linksByDeviceId: [String: LanLink] = [:]

    /// Interval between repeated identity broadcasts.
    public static let broadcastInterval: TimeInterval = 5

    public init() {}

    public func start() throws {
        try CertificateService.shared.ensureIdentity()
        let (channel, port) = try NIOTransport.shared.startListener(
            portRange: Settings.minTCPPort...Settings.maxTCPPort,
            onIdentity: { [weak self] identity, channel in
                self?.handleIdentity(identity, channel: channel)
            },
            onPacket: { [weak self] packet, channel in
                self?.handlePacket(packet, channel: channel)
            },
            onSecured: { [weak self] channel in
                self?.handleSecured(channel: channel)
            },
            onClose: { [weak self] channel, _ in
                self?.handleClosed(channel: channel)
            }
        )
        self.serverChannel = channel
        self.tcpPort = port
        Log.net.info("TCP listener on \(port, privacy: .public)")

        try startUDPListener()
        startBroadcastTimer()
        broadcastIdentity()
    }

    public func stop() {
        broadcastTimer?.cancel()
        broadcastTimer = nil
        udpListener?.cancel()
        udpListener = nil
        try? serverChannel?.close().wait()
        serverChannel = nil
    }

    public func refresh() {
        broadcastIdentity()
    }

    /// Look up the peer's IP for an active link, used for opening payload
    /// connections back to the same peer.
    public func peerHost(for deviceId: String) -> String? {
        linkLock.lock()
        let link = linksByDeviceId[deviceId]
        linkLock.unlock()
        guard let remote = link?.activeChannel.remoteAddress else { return nil }
        switch remote {
        case .v4(let v4):
            var addr = v4.address.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
            return String(cString: buf)
        case .v6(let v6):
            var addr = v6.address.sin6_addr
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
            return String(cString: buf)
        case .unixDomainSocket:
            return nil
        }
    }

    private func startBroadcastTimer() {
        broadcastTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.broadcastInterval, repeating: Self.broadcastInterval)
        timer.setEventHandler { [weak self] in
            self?.broadcastIdentity()
        }
        timer.resume()
        broadcastTimer = timer
    }

    // MARK: - Channel callbacks

    private func handleIdentity(_ identity: IdentityPayload, channel: Channel) {
        Log.net.info("Identity from \(identity.deviceName, privacy: .public) (\(identity.deviceId, privacy: .public))")
        linkLock.lock()
        if let existing = linksByDeviceId[identity.deviceId] {
            // Already have a link for this device. Replace the underlying
            // channel with the newer one so sends always go on the most
            // recent connection. Both peers do this independently and end
            // up agreeing on the same active channel.
            let oldChannel = existing.activeChannel
            existing.replaceChannel(with: channel)
            channelToDeviceId.removeValue(forKey: ObjectIdentifier(oldChannel))
            channelToDeviceId[ObjectIdentifier(channel)] = identity.deviceId
            linkLock.unlock()
            Log.net.info("Replaced channel for existing link \(identity.deviceId, privacy: .public)")
            Task { @MainActor in
                _ = DeviceManager.shared.upsert(identity: identity)
            }
            return
        }
        let link = LanLink(
            deviceId: identity.deviceId,
            channel: channel,
            onPacket: { [weak self] packet in
                Task { @MainActor in
                    self?.dispatch(packet, identity: identity)
                }
            },
            onClose: { [weak self] in
                self?.linkLock.lock()
                self?.linksByDeviceId.removeValue(forKey: identity.deviceId)
                self?.linkLock.unlock()
                Task { @MainActor in
                    DeviceManager.shared.detach(deviceId: identity.deviceId)
                }
            }
        )
        linksByDeviceId[identity.deviceId] = link
        channelToDeviceId[ObjectIdentifier(channel)] = identity.deviceId
        linkLock.unlock()
        Task { @MainActor in
            _ = DeviceManager.shared.upsert(identity: identity)
        }
    }

    private func handlePacket(_ packet: NetworkPacket, channel: Channel) {
        linkLock.lock()
        let deviceId = channelToDeviceId[ObjectIdentifier(channel)]
        let link = deviceId.flatMap { linksByDeviceId[$0] }
        linkLock.unlock()
        guard let link else {
            Log.net.warning("Packet on unknown channel; dropping (\(packet.type, privacy: .public))")
            return
        }
        link.deliverPacket(packet)
    }

    private func handleSecured(channel: Channel) {
        linkLock.lock()
        guard let deviceId = channelToDeviceId[ObjectIdentifier(channel)],
              let link = linksByDeviceId[deviceId] else {
            linkLock.unlock()
            return
        }
        link.isSecure = true
        linkLock.unlock()
        Log.net.info("Link secured: \(deviceId, privacy: .public)")
        Task { @MainActor in
            DeviceManager.shared.attach(link: link, to: deviceId)
        }
    }

    private func handleClosed(channel: Channel) {
        linkLock.lock()
        guard let deviceId = channelToDeviceId.removeValue(forKey: ObjectIdentifier(channel)) else {
            linkLock.unlock()
            return
        }
        // Only tear down the device link if THIS channel is still the active one
        // for that device. If it was already replaced, this is the old socket
        // closing — don't disconnect the device.
        let link = linksByDeviceId[deviceId]
        let isActive = link?.activeChannel === channel
        if isActive {
            linksByDeviceId.removeValue(forKey: deviceId)
        }
        linkLock.unlock()
        if isActive {
            link?.notifyClosed()
        }
    }

    @MainActor
    private func dispatch(_ packet: NetworkPacket, identity: IdentityPayload) {
        let device = DeviceManager.shared.upsert(identity: identity)
        Log.plugin.info("Recv \(packet.type, privacy: .public) from \(identity.deviceName, privacy: .public)")
        if packet.type == PacketType.pair {
            handlePairPacket(packet, device: device)
            return
        }
        guard Settings.shared.isTrusted(device.id) else {
            Log.plugin.notice("Drop (untrusted) \(packet.type, privacy: .public) from \(device.id, privacy: .public)")
            return
        }
        Task { @MainActor in
            await PluginRegistry.shared.dispatch(packet, from: device)
        }
    }

    @MainActor
    private func handlePairPacket(_ packet: NetworkPacket, device: Device) {
        let accept = packet.body["pair"]?.boolValue ?? false
        DeviceManager.shared.didReceivePairPacket(accept: accept, device: device)
    }

    // MARK: - UDP discovery

    private func startUDPListener() throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: Settings.udpPort)!
        let listener = try NWListener(using: params, on: port)

        listener.newConnectionHandler = { [weak self] incoming in
            incoming.start(queue: self?.queue ?? .main)
            incoming.receiveMessage { data, _, _, _ in
                guard let self, let data else { return }
                self.handleUDPIdentity(data, from: incoming.endpoint)
                incoming.cancel()
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                Log.net.error("UDP listener failed: \(err.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: queue)
        self.udpListener = listener
        Log.net.info("UDP listener on \(Settings.udpPort, privacy: .public)")
    }

    private func handleUDPIdentity(_ data: Data, from endpoint: NWEndpoint) {
        let payload = data.last == 0x0A ? data.dropLast() : data
        guard let packet = try? NetworkPacket.parse(payload),
              let identity = IdentityPayload.from(packet: packet) else { return }
        if identity.deviceId == Settings.shared.deviceId { return }
        Log.net.debug("UDP identity from \(identity.deviceName, privacy: .public)")

        guard let port = identity.tcpPort, (1714...1764).contains(port) else { return }
        guard case .hostPort(let host, _) = endpoint else { return }
        let hostStr: String
        switch host {
        case .ipv4(let ip): hostStr = "\(ip)"
        case .ipv6(let ip): hostStr = "\(ip)"
        case .name(let n, _): hostStr = n
        @unknown default: return
        }

        // Avoid double-connecting if we already have a secured link
        linkLock.lock()
        let existing = linksByDeviceId[identity.deviceId]
        linkLock.unlock()
        if let existing, existing.isSecure { return }

        Log.net.info("Connecting to \(identity.deviceName, privacy: .public) at \(hostStr, privacy: .public):\(port, privacy: .public)")

        let future = NIOTransport.shared.connect(
            host: hostStr,
            port: UInt16(port),
            peerIdentity: identity,
            onPacket: { [weak self] packet, channel in
                self?.handlePacket(packet, channel: channel)
            },
            onSecured: { [weak self] channel in
                self?.handleSecured(channel: channel)
            },
            onClose: { [weak self] channel, _ in
                self?.handleClosed(channel: channel)
            }
        )
        future.whenSuccess { [weak self] channel in
            // For outbound, the handler already knows peer identity; register the link now.
            self?.handleIdentity(identity, channel: channel)
        }
        future.whenFailure { err in
            Log.net.error("Outbound connect failed to \(hostStr, privacy: .public): \(err.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - UDP broadcast

    public func broadcastIdentity() {
        guard serverChannel != nil else { return }
        let identity = Settings.shared.ownIdentity(tcpPort: Int(tcpPort))
        guard let data = try? identity.toPacket().serialized() else { return }

        let interfaces = NetworkInterfaces.ipv4Broadcasts()
        var targets = Set(interfaces.map(\.broadcast))
        targets.insert("255.255.255.255")
        if interfaces.isEmpty {
            Log.net.warning("No broadcast-capable IPv4 interfaces found")
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            Log.net.error("socket() failed errno=\(errno, privacy: .public)")
            return
        }
        defer { close(fd) }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var ok = 0
        for addr in targets.sorted() {
            var sin = sockaddr_in()
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = Settings.udpPort.bigEndian
            guard inet_pton(AF_INET, addr, &sin.sin_addr) == 1 else { continue }

            let sent = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
                withUnsafePointer(to: &sin) { ptr -> Int in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int in
                        sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 {
                Log.net.error("Broadcast to \(addr, privacy: .public) failed errno=\(errno, privacy: .public)")
            } else {
                ok += 1
            }
        }
        Log.net.debug("Broadcast identity to \(ok, privacy: .public) target(s)")
    }
}
