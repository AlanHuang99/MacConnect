import Darwin
import Foundation
import Network
import NIOCore

/// Owns UDP discovery + TCP server. Discovers peers and creates secure links.
///
/// Discovery is via UDP broadcast (subnet-directed + 255.255.255.255) on port
/// 1716. Each link's plain-TCP-then-TLS handshake is implemented in
/// ``KDEConnectChannelHandler``.
public final class LanLinkProvider: @unchecked Sendable {
    public static let shared = LanLinkProvider()

    private let queue = DispatchQueue(label: "macconnect.lanprovider")
    private var udpListener: NWListener?
    private var mdnsBrowser: NWBrowser?
    private var serverChannel: Channel?
    private var tcpPort: UInt16 = Settings.minTCPPort
    private var broadcastTimer: DispatchSourceTimer?
    /// Long-lived UDP socket used for the periodic identity broadcast.
    /// `-1` means closed / not yet opened. Opened once in `start()`, reused
    /// every 5 s instead of socket-create-then-close on each tick.
    private var broadcastFD: Int32 = -1
    private let linkLock = NSLock()
    private var channelToDeviceId: [ObjectIdentifier: String] = [:]
    private var linksByDeviceId: [String: LanLink] = [:]

    /// Bonjour service type advertised + browsed for. Matches KDE Connect's
    /// canonical mDNS service name; using anything else would break
    /// interoperability with KDE Connect's mDNS-aware clients.
    public static let bonjourServiceType = "_kdeconnect._udp"

    /// Interval between repeated identity broadcasts.
    public static let broadcastInterval: TimeInterval = 5

    public init() {}

    public func start() throws {
        try CertificateService.shared.ensureIdentity()
        let (channel, port) = try NIOTransport.shared.startListener(
            portRange: Settings.minTCPPort ... Settings.maxTCPPort,
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
        serverChannel = channel
        tcpPort = port
        Log.net.info("TCP listener on \(port, privacy: .public)")

        try startUDPListener()
        startMDNSBrowser()
        // broadcastFD is owned by `queue`; open it from there so the long-
        // lived socket has a single confinement point.
        queue.sync { self.openBroadcastSocketOnQueue() }
        startBroadcastTimer()
        broadcastIdentity()
    }

    /// Open the long-lived UDP broadcast socket. MUST run on `queue` —
    /// `broadcastFD` is owned by that queue and is racy if read or written
    /// from anywhere else.
    private func openBroadcastSocketOnQueue() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            Log.net.error("socket() for broadcast failed errno=\(errno, privacy: .public)")
            return
        }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        broadcastFD = fd
    }

    /// Tear down the discovery + listener stack with a hard deadline.
    ///
    /// Per-channel TCP graceful close requires a peer FIN-ACK; an offline
    /// peer leaves the kernel waiting the full TCP close timeout (tens of
    /// seconds). Without a deadline this directly translates to a slow
    /// Quit menu. We fire all closes in parallel, wait up to `deadline`
    /// for them to settle, then move on and let the kernel reap whatever
    /// remains as the process exits.
    public func stop(deadline: DispatchTime = .now() + 1.0) {
        broadcastTimer?.cancel()
        broadcastTimer = nil
        udpListener?.cancel()
        udpListener = nil
        mdnsBrowser?.cancel()
        mdnsBrowser = nil
        // Close the broadcast socket on its owning queue so a concurrent
        // broadcastIdentity tick can't sendto() a descriptor that was just
        // closed (or already recycled for another resource).
        queue.sync {
            if self.broadcastFD >= 0 {
                close(self.broadcastFD)
                self.broadcastFD = -1
            }
        }

        // Snapshot active links under the lock then close OUTSIDE it. We
        // intentionally do NOT clear the maps yet: closing a channel fires
        // `handleClosed` on the event loop, which needs the maps populated
        // so it can resolve the deviceId and invoke `link.notifyClosed()`.
        linkLock.lock()
        let activeLinks = Array(linksByDeviceId.values)
        linkLock.unlock()

        // Fan all closes out at once, count them down with a DispatchGroup
        // so we can bound the total wait.
        let group = DispatchGroup()
        for link in activeLinks {
            group.enter()
            link.activeChannel.close().whenComplete { _ in group.leave() }
        }
        if let serverChannel {
            group.enter()
            serverChannel.close().whenComplete { _ in group.leave() }
        }
        if group.wait(timeout: deadline) == .timedOut {
            Log.net.notice("stop() timed out waiting for channel closes; proceeding")
        }

        // Belt-and-braces sweep: anything `handleClosed` didn't drain (e.g.
        // a close path that doesn't fire it, or a wait that timed out
        // before NIO finished) gets cleaned up here.
        linkLock.lock()
        let stragglers = Array(linksByDeviceId.values)
        linksByDeviceId.removeAll()
        channelToDeviceId.removeAll()
        linkLock.unlock()
        for link in stragglers {
            link.notifyClosed()
        }

        serverChannel = nil
    }

    public func refresh() {
        broadcastIdentity()
    }

    private func isLocalAddress(_ remote: SocketAddress) -> Bool {
        let host: String
        switch remote {
        case .v4(let v4):
            var addr = v4.address.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
            host = String(cString: buf)
        case .v6(let v6):
            var addr = v6.address.sin6_addr
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
            host = String(cString: buf)
        case .unixDomainSocket:
            return false
        }
        return NetworkInterfaces.localIPv4Addresses().contains(host)
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
        // Same defence as in UDP discovery: reject any inbound TCP from one
        // of our own interface IPs. Catches the case where another
        // KDE Connect implementation on the same Mac is connecting to us.
        if let remote = channel.remoteAddress, isLocalAddress(remote) {
            Log.net.debug("Ignoring TCP identity from local address; closing")
            channel.close(promise: nil)
            return
        }
        if identity.deviceId == Settings.shared.deviceId {
            Log.net.debug("Ignoring TCP identity matching our own deviceId; closing")
            channel.close(promise: nil)
            return
        }
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
                // Re-bind to a let so the inner Task does not capture an
                // optional reference to `self` from the outer closure
                // (which strict-concurrency checking on Swift 5.10 treats as
                // a concurrent read of a captured var).
                let provider = self
                Task { @MainActor in
                    provider?.dispatch(packet, identity: identity)
                }
            },
            onClose: { [weak self] in
                let provider = self
                provider?.linkLock.lock()
                provider?.linksByDeviceId.removeValue(forKey: identity.deviceId)
                provider?.linkLock.unlock()
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
              let link = linksByDeviceId[deviceId]
        else {
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

        // Advertise via Bonjour alongside UDP broadcast. mDNS-aware peers
        // (KDE Connect Linux, recent Android) find us without needing
        // broadcast packets to make it past mesh APs / AP isolation.
        listener.service = NWListener.Service(
            name: Settings.shared.deviceName,
            type: Self.bonjourServiceType
        )

        listener.newConnectionHandler = { [weak self] incoming in
            let provider = self
            incoming.start(queue: provider?.queue ?? .main)
            incoming.receiveMessage { data, _, _, _ in
                guard let provider, let data else { return }
                provider.handleUDPIdentity(data, from: incoming.endpoint)
                incoming.cancel()
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                Log.net.error("UDP listener failed: \(err.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: queue)
        udpListener = listener
        Log.net
            .info(
                "UDP listener on \(Settings.udpPort, privacy: .public) (also advertising \(Self.bonjourServiceType, privacy: .public))"
            )
    }

    // MARK: - mDNS browse

    private func startMDNSBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            for change in changes {
                switch change {
                case .added(let result):
                    self?.handleMDNSResult(result)
                case .changed(_, let result, _):
                    self?.handleMDNSResult(result)
                case .removed, .identical:
                    break
                @unknown default:
                    break
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                Log.net.error("mDNS browser failed: \(err.localizedDescription, privacy: .public)")
            }
        }
        browser.start(queue: queue)
        mdnsBrowser = browser
        Log.net.info("mDNS browser searching \(Self.bonjourServiceType, privacy: .public)")
    }

    /// Send our identity directly to a peer discovered via mDNS. The peer's
    /// UDP listener will see our identity payload and TCP-connect back
    /// through the existing flow — no separate code path needed past this
    /// point. Self-discovery is harmless: handleUDPIdentity filters by
    /// deviceId.
    private func handleMDNSResult(_ result: NWBrowser.Result) {
        guard serverChannel != nil else { return }
        let identity = Settings.shared.ownIdentity(tcpPort: Int(tcpPort))
        guard let data = try? identity.toPacket().serialized() else { return }

        let connection = NWConnection(to: result.endpoint, using: .udp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .failed(let err):
                Log.net.debug("mDNS-target send failed: \(err.localizedDescription, privacy: .public)")
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func handleUDPIdentity(_ data: Data, from endpoint: NWEndpoint) {
        let payload = data.last == 0x0A ? data.dropLast() : data
        guard let packet = try? NetworkPacket.parse(payload),
              let identity = IdentityPayload.from(packet: packet) else { return }
        if identity.deviceId == Settings.shared.deviceId { return }

        guard let port = identity.tcpPort, (1714 ... 1764).contains(port) else { return }
        guard case .hostPort(let host, _) = endpoint else { return }
        let hostStr: String
        switch host {
        case .ipv4(let ip): hostStr = "\(ip)"
        case .ipv6(let ip): hostStr = "\(ip)"
        case .name(let n, _): hostStr = n
        @unknown default: return
        }

        // Reject broadcasts that originate from one of our own interface
        // addresses. Another KDE Connect implementation running on the same
        // machine has a different deviceId from ours but reaches us as a
        // loopback peer; without this, MacConnect would list its host as a
        // remote device.
        if NetworkInterfaces.localIPv4Addresses().contains(hostStr) {
            Log.net.debug("Ignoring UDP identity from local address \(hostStr, privacy: .public)")
            return
        }
        Log.net.debug("UDP identity from \(identity.deviceName, privacy: .public)")

        // Avoid double-connecting if we already have a secured link
        linkLock.lock()
        let existing = linksByDeviceId[identity.deviceId]
        linkLock.unlock()
        if let existing, existing.isSecure { return }

        Log.net
            .info(
                "Connecting to \(identity.deviceName, privacy: .public) at \(hostStr, privacy: .public):\(port, privacy: .public)"
            )

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
            Log.net
                .error(
                    "Outbound connect failed to \(hostStr, privacy: .public): \(err.localizedDescription, privacy: .public)"
                )
        }
    }

    // MARK: - UDP broadcast

    public func broadcastIdentity() {
        // broadcastFD is owned by `queue` (see openBroadcastSocketOnQueue /
        // stop). Bounce here so callers from any thread (refresh from the
        // main actor, the timer event handler from the queue itself, the
        // initial fire from start) all converge on the same confinement
        // point.
        queue.async { self.broadcastIdentityOnQueue() }
    }

    private func broadcastIdentityOnQueue() {
        guard serverChannel != nil else { return }
        // Self-heal if a transient startup failure (EMFILE, etc.) left us
        // without an fd. The per-tick model used to recover automatically;
        // a long-lived socket must do this explicitly or peer discovery
        // stays permanently dead for the run.
        if broadcastFD < 0 {
            openBroadcastSocketOnQueue()
            guard broadcastFD >= 0 else { return }
        }
        let identity = Settings.shared.ownIdentity(tcpPort: Int(tcpPort))
        guard let data = try? identity.toPacket().serialized() else { return }

        let interfaces = NetworkInterfaces.ipv4Broadcasts()
        var targets = Set(interfaces.map(\.broadcast))
        targets.insert("255.255.255.255")
        if interfaces.isEmpty {
            Log.net.warning("No broadcast-capable IPv4 interfaces found")
        }

        let fd = broadcastFD
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
