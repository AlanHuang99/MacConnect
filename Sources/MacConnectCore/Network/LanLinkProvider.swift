import Foundation
import Network
import Darwin

/// Owns UDP discovery + TCP server. Discovers peers, opens links.
///
/// Status: protocol v0 of MacConnect implements UDP discovery and plain-TCP
/// identity exchange only. TLS upgrade (KDE Connect's startTLS-after-identity
/// pattern) is the next milestone — see ``upgradeTLS(_:role:)``.
public final class LanLinkProvider: @unchecked Sendable {
    public static let shared = LanLinkProvider()

    private let queue = DispatchQueue(label: "macconnect.lanprovider")
    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var tcpPort: UInt16 = Settings.minTCPPort
    private var broadcastTimer: DispatchSourceTimer?

    /// Interval between repeated identity broadcasts. KDE Connect Android
    /// rebroadcasts on network change; we emit on a short timer too so phones
    /// that join the network mid-session (or that were briefly off-Wi-Fi)
    /// pick us up without a manual refresh.
    public static let broadcastInterval: TimeInterval = 5

    private let _onIdentityCallback: AtomicBox<(IdentityPayload, LanLink) -> Void> = .init({ _, _ in })

    public init() {}

    public func onIdentity(_ cb: @escaping (IdentityPayload, LanLink) -> Void) {
        _onIdentityCallback.set(cb)
    }

    public func start() throws {
        try CertificateService.shared.ensureIdentity()
        try startTCPListener()
        try startUDPListener()
        startBroadcastTimer()
        broadcastIdentity()
    }

    public func stop() {
        broadcastTimer?.cancel()
        broadcastTimer = nil
        udpListener?.cancel()
        tcpListener?.cancel()
        udpListener = nil
        tcpListener = nil
    }

    public func refresh() {
        broadcastIdentity()
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

    // MARK: TCP server

    private func startTCPListener() throws {
        // NWListener bind failures arrive asynchronously via stateUpdateHandler,
        // so we attempt each port and wait synchronously for it to become
        // .ready or .failed before deciding whether to walk to the next.
        for port in Settings.minTCPPort...Settings.maxTCPPort {
            let semaphore = DispatchSemaphore(value: 0)
            var didFail = false
            var listener: NWListener?
            do {
                let params = NWParameters.tcp
                let nwPort = NWEndpoint.Port(rawValue: port)!
                let l = try NWListener(using: params, on: nwPort)
                l.newConnectionHandler = { [weak self] conn in
                    self?.handleIncomingTCP(conn)
                }
                l.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        semaphore.signal()
                    case .failed(let err):
                        Log.net.error("TCP listener bind \(port, privacy: .public) failed: \(err.localizedDescription, privacy: .public)")
                        didFail = true
                        semaphore.signal()
                    case .cancelled:
                        semaphore.signal()
                    default: break
                    }
                }
                l.start(queue: queue)
                listener = l
            } catch {
                continue
            }

            // Bound wait — if neither .ready nor .failed lands fast, treat as failed.
            let result = semaphore.wait(timeout: .now() + 1.0)
            if result == .timedOut || didFail {
                listener?.cancel()
                continue
            }
            self.tcpListener = listener
            self.tcpPort = port
            Log.net.info("TCP listener on \(port, privacy: .public)")
            return
        }
        throw NSError(domain: "MacConnect.Net", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "No free TCP port in range \(Settings.minTCPPort)-\(Settings.maxTCPPort)"])
    }

    private func handleIncomingTCP(_ conn: NWConnection) {
        // Phase 1: receive plain-TCP identity packet
        // Phase 2 (TODO): startTLS as server, requiring client cert
        conn.start(queue: queue)
        readIdentity(from: conn) { [weak self] identity in
            guard let self, let identity else {
                conn.cancel()
                return
            }
            Log.net.info("Incoming TCP identity from \(identity.deviceName, privacy: .public)")
            let link = LanLink(
                deviceId: identity.deviceId,
                connection: conn,
                onPacket: { packet in
                    self.dispatch(packet, identity: identity)
                },
                onClose: {
                    Task { @MainActor in DeviceManager.shared.detach(deviceId: identity.deviceId) }
                }
            )
            self._onIdentityCallback.value(identity, link)
            link.start()
        }
    }

    private func readIdentity(from conn: NWConnection, completion: @escaping (IdentityPayload?) -> Void) {
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, err in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if let lf = buffer.firstIndex(of: 0x0A) {
                        let line = buffer.subdata(in: buffer.startIndex..<lf)
                        if let packet = try? NetworkPacket.parse(line),
                           let id = IdentityPayload.from(packet: packet) {
                            completion(id)
                            return
                        }
                        completion(nil)
                        return
                    }
                }
                if isComplete || err != nil {
                    completion(nil)
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    // MARK: UDP discovery

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
              let identity = IdentityPayload.from(packet: packet) else {
            return
        }
        if identity.deviceId == Settings.shared.deviceId {
            return // our own broadcast
        }
        Log.net.info("UDP identity from \(identity.deviceName, privacy: .public) (\(identity.deviceId, privacy: .public))")
        // Connect to peer's TCP port to complete handshake
        guard let port = identity.tcpPort, (1714...1764).contains(port) else { return }
        guard case .hostPort(let host, _) = endpoint else { return }
        connectAndSendIdentity(host: host, port: NWEndpoint.Port(rawValue: UInt16(port))!, peerIdentity: identity)
    }

    private func connectAndSendIdentity(host: NWEndpoint.Host, port: NWEndpoint.Port, peerIdentity: IdentityPayload) {
        let conn = NWConnection(host: host, port: port, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let identity = Settings.shared.ownIdentity(tcpPort: Int(self.tcpPort))
                if let data = try? identity.toPacket().serialized() {
                    conn.send(content: data, completion: .contentProcessed { _ in })
                }
                // TODO: After this write completes, this is where we would startTLS
                // as the TLS client. Tracked in TODO.md.
                let link = LanLink(
                    deviceId: peerIdentity.deviceId,
                    connection: conn,
                    onPacket: { packet in
                        self.dispatch(packet, identity: peerIdentity)
                    },
                    onClose: {
                        Task { @MainActor in DeviceManager.shared.detach(deviceId: peerIdentity.deviceId) }
                    }
                )
                self._onIdentityCallback.value(peerIdentity, link)
                link.start()
            case .failed(let err):
                Log.net.error("Outbound TCP failed: \(err.localizedDescription, privacy: .public)")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    // MARK: UDP broadcast

    public func broadcastIdentity() {
        guard tcpListener != nil else { return }
        let identity = Settings.shared.ownIdentity(tcpPort: Int(tcpPort))
        guard let data = try? identity.toPacket().serialized() else { return }

        // Compute subnet-directed broadcast targets per active interface.
        // Limited broadcast (255.255.255.255) is filtered by many Wi-Fi APs;
        // 192.168.x.255 traverses the local segment reliably.
        let interfaces = NetworkInterfaces.ipv4Broadcasts()
        var targets = Set(interfaces.map(\.broadcast))
        targets.insert("255.255.255.255") // belt + suspenders
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
        Log.net.debug("Broadcast identity to \(ok, privacy: .public) target(s) (\(targets.count, privacy: .public) attempted)")
    }

    // MARK: Dispatch

    private func dispatch(_ packet: NetworkPacket, identity: IdentityPayload) {
        Task { @MainActor in
            let device = DeviceManager.shared.upsert(identity: identity)
            // Pair packet handling first (before plugins)
            if packet.type == PacketType.pair {
                self.handlePairPacket(packet, device: device)
                return
            }
            // Plugins only run for trusted devices
            guard Settings.shared.isTrusted(device.id) else {
                Log.pair.notice("Dropping \(packet.type, privacy: .public) from untrusted \(device.id, privacy: .public)")
                return
            }
            await PluginRegistry.shared.dispatch(packet, from: device)
        }
    }

    @MainActor
    private func handlePairPacket(_ packet: NetworkPacket, device: Device) {
        let pair = packet.body["pair"]?.boolValue ?? false
        if pair {
            // Pair request — surface to user
            device.pairRequestPending = true
            DeviceManager.shared.objectWillChange.send()
        } else {
            // Unpair / rejection
            Settings.shared.unmarkTrusted(device.id)
            device.isPaired = false
            device.pairRequestPending = false
            DeviceManager.shared.objectWillChange.send()
        }
    }
}

final class AtomicBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ newValue: T) {
        lock.lock(); defer { lock.unlock() }
        _value = newValue
    }
}
