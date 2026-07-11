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

    /// Per-peer dial cooldown so a peer whose TLS handshake keeps
    /// failing doesn't get redialed every 5 s discovery tick. Without
    /// this, a single broken peer (e.g. an incompatible iOS build)
    /// produces hundreds of failed handshakes per minute, eats fds /
    /// CPU, and makes the app appear hung. See `DialCooldownTracker`
    /// for the backoff schedule.
    private var dialCooldown = DialCooldownTracker()

    /// Watches for connectivity returning / interfaces changing so we can
    /// rebuild discovery after sleep or a Wi-Fi switch. See
    /// ``startPathMonitor()`` and ``restartDiscovery()``.
    private var pathMonitor: NWPathMonitor?
    /// Coalesces a burst of wake / path-change triggers into one rebuild.
    private var pendingRestart: DispatchWorkItem?
    /// NWPathMonitor delivers the current path as its first callback; that
    /// baseline is the state discovery was just built for, so we record it
    /// without rebuilding. Touched only on `queue`.
    private var pathMonitorPrimed = false
    /// Last seen path signature (status + interface names); a rebuild fires
    /// only when this changes. Touched only on `queue`.
    private var lastPathSignature = ""
    /// `true` once `start()` has built the stack; gates `restartDiscovery()`
    /// so a path callback can't rebuild before the first build. Set/cleared
    /// on `queue`.
    private var didStart = false

    /// Incarnation counter for the UDP listener. Every (re)build and
    /// teardown advances it, so a delayed rebind retry scheduled by an
    /// earlier listener no-ops instead of double-binding against the
    /// current one. Touched only on `queue`.
    private var udpGeneration = 0
    /// Consecutive failed bind attempts for the current UDP listener
    /// incarnation; indexes the rebind backoff. Touched only on `queue`.
    private var udpRebindAttempts = 0

    /// Latest identity announcement per device, with per-host timestamps.
    /// Written by `handleUDPIdentity` for every validated announcement,
    /// whether or not it leads to a dial. Read by the liveness reconciler
    /// (is the peer still announcing? where do we re-dial it?) and by the
    /// stale-host check (did the address our link points at stop
    /// announcing, or is the peer just multi-homed?). Guarded by
    /// `linkLock`: written on `queue`, read from the main actor.
    private struct Announcement {
        var identity: IdentityPayload
        var host: String
        var port: UInt16
        var at: Date
        var hostsLastSeen: [String: Date]
    }

    private var announcements: [String: Announcement] = [:]

    /// A peer (or one of its addresses) whose last announcement is older
    /// than this has stopped announcing. Six missed 5 s broadcast ticks —
    /// generous enough that ordinary UDP loss doesn't look like departure.
    public static let announceQuietThreshold: TimeInterval = 30

    /// Announcements older than this are pruned entirely so departed
    /// peers don't accumulate.
    private static let announcementMaxAge: TimeInterval = 600

    /// Test seam: when non-nil, replaces `NetworkInterfaces.localIPv4Addresses()`
    /// in the self-traffic rejection checks. The in-process regression
    /// harness (LanLinkHarnessTests) drives a real provider against a fake
    /// peer over loopback, which the production check would reject as our
    /// own traffic. Set it before any traffic flows; production leaves it
    /// nil.
    var localAddressesOverride: Set<String>?

    private func localAddresses() -> Set<String> {
        localAddressesOverride ?? NetworkInterfaces.localIPv4Addresses()
    }

    /// Debounce window for `restartDiscovery()`. A wake bounces interfaces
    /// several times over a second or two; coalesce those into one rebuild.
    public static let restartDebounceInterval: TimeInterval = 1.5

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

        // Build the UDP listener, mDNS browser, and broadcast socket/timer
        // on `queue` so a wake / network-change rebuild (restartDiscovery)
        // can't race their setup — every mutation of these lives on `queue`.
        queue.sync { self.setupDiscoveryOnQueue() }
        broadcastIdentity()
        // Watch for sleep/wake and Wi-Fi changes so discovery rebuilds itself
        // instead of staying dead until the user restarts the app.
        startPathMonitor()
    }

    /// Build (or rebuild) the discovery stack. MUST run on `queue`. Safe to
    /// call again after `teardownDiscoveryOnQueue()` to rebind on the
    /// current interfaces after a wake or network change.
    private func setupDiscoveryOnQueue() {
        do {
            try startUDPListener()
        } catch {
            // Non-fatal: broadcast + mDNS still find peers, and the
            // scheduled rebind below keeps trying until the port frees.
            Log.net.error("UDP listener bind failed: \(error.localizedDescription, privacy: .public)")
            scheduleUDPRebind(generation: udpGeneration)
        }
        startMDNSBrowser()
        openBroadcastSocketOnQueue()
        startBroadcastTimer()
        didStart = true
    }

    /// Tear down the discovery stack. MUST run on `queue`. Pairs with
    /// `setupDiscoveryOnQueue()` for a clean rebuild.
    private func teardownDiscoveryOnQueue() {
        broadcastTimer?.cancel()
        broadcastTimer = nil
        // Advance the generation and detach the state handler BEFORE
        // cancelling: a dying listener can emit one last `.failed`, and
        // without these it would schedule a rebind against the fresh
        // listener the caller is about to build.
        udpGeneration += 1
        udpListener?.stateUpdateHandler = nil
        udpListener?.cancel()
        udpListener = nil
        mdnsBrowser?.cancel()
        mdnsBrowser = nil
        if broadcastFD >= 0 {
            close(broadcastFD)
            broadcastFD = -1
        }
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
        pathMonitor?.cancel()
        pathMonitor = nil
        broadcastTimer?.cancel()
        broadcastTimer = nil
        udpListener?.cancel()
        udpListener = nil
        mdnsBrowser?.cancel()
        mdnsBrowser = nil
        // Close the broadcast socket on its owning queue so a concurrent
        // broadcastIdentity tick can't sendto() a descriptor that was just
        // closed (or already recycled for another resource). Cancel any
        // pending restart and clear `didStart` here too so a path callback
        // racing teardown can't schedule a rebuild against a dead provider.
        queue.sync {
            self.pendingRestart?.cancel()
            self.pendingRestart = nil
            self.didStart = false
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
        dialCooldown.removeAll()
        announcements.removeAll()
        linkLock.unlock()
        // Drop the shared link reference so links don't outlive the provider.
        for link in stragglers {
            link.notifyClosed()
        }

        serverChannel = nil
    }

    public func refresh() {
        broadcastIdentity()
    }

    /// Re-announce immediately (instant feedback) then rebuild the discovery
    /// stack. Wired to the popover's refresh button so a manual refresh
    /// genuinely re-discovers — matching its "Re-broadcast & re-discover"
    /// label — instead of only re-broadcasting on a stack that died at sleep.
    public func rediscover() {
        broadcastIdentity()
        restartDiscovery()
    }

    /// Rebuild discovery on the current interfaces and force every peer link
    /// to re-establish. This is the programmatic equivalent of quitting and
    /// relaunching the app, which until now was the only way to recover.
    ///
    /// Why it's needed: across a sleep/wake or a Wi-Fi change the NWListener
    /// (UDP), NWBrowser (mDNS), and broadcast socket stop delivering on the
    /// now-stale interfaces and never self-restart. Compounding that, a peer
    /// link whose TCP socket died while we slept stays marked `secure`, so
    /// `handleUDPIdentity`'s `existing.isSecure` guard skips re-dialing it
    /// until OS keepalive reaps the socket (~60 s) — and the just-woken side
    /// can't be found at all until its listener is rebuilt. Dropping the
    /// links here lets peers reconnect within one discovery tick.
    ///
    /// Debounced on `queue`: a wake produces a burst of NWPathMonitor
    /// callbacks as interfaces bounce; coalesce them into a single rebuild.
    public func restartDiscovery() {
        queue.async { [weak self] in
            guard let self, self.didStart else { return }
            self.pendingRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.performRestartOnQueue() }
            self.pendingRestart = work
            self.queue.asyncAfter(deadline: .now() + Self.restartDebounceInterval, execute: work)
        }
    }

    private func performRestartOnQueue() {
        guard serverChannel != nil else { return }
        Log.net.notice("Rebuilding discovery stack (wake / network change / manual refresh)")
        dropAllLinksForRestart()
        teardownDiscoveryOnQueue()
        setupDiscoveryOnQueue()
        broadcastIdentityOnQueue()
    }

    /// Close and forget every peer link so they reconnect cleanly after a
    /// wake / network change. Runs on `queue`. `handleClosed` no-ops for
    /// these channels because we clear the channel→deviceId map first; we
    /// fire `notifyClosed()` ourselves so DeviceManager marks each device
    /// offline (both paths are idempotent).
    private func dropAllLinksForRestart() {
        linkLock.lock()
        let links = Array(linksByDeviceId.values)
        linksByDeviceId.removeAll()
        channelToDeviceId.removeAll()
        dialCooldown.removeAll()
        linkLock.unlock()
        for link in links {
            link.disconnect()
            link.notifyClosed()
        }
    }

    /// Force a single peer's link down. Used by the liveness reconciler when a
    /// device exceeds its freshness TTL with no close / wake / path event to
    /// rely on. Mirrors `dropAllLinksForRestart` for one device: pull it from
    /// the maps (so the eventual channel-close is a no-op), clear its dial
    /// cooldown so it can redial immediately, disconnect the socket, and fire
    /// `notifyClosed` so `DeviceManager.detach` marks it offline. Idempotent —
    /// a no-op if the link is already gone.
    public func dropLink(deviceId: String) {
        queue.async { [weak self] in
            self?.dropLinkOnQueue(deviceId: deviceId)
        }
    }

    /// Body of `dropLink` for callers already on `queue` that need the
    /// drop completed synchronously before they re-dial (the stale-host
    /// path in `handleUDPIdentity`). Same lock discipline as everywhere
    /// else: snapshot and remove under `linkLock`, then disconnect and
    /// notify OUTSIDE it — `Channel.close()` can synchronously re-enter
    /// `handleClosed` → `linkLock` (the 0.3.7 deadlock).
    private func dropLinkOnQueue(deviceId: String) {
        linkLock.lock()
        let link = linksByDeviceId.removeValue(forKey: deviceId)
        if let link {
            channelToDeviceId.removeValue(forKey: ObjectIdentifier(link.activeChannel))
        }
        dialCooldown.clear(deviceId: deviceId)
        linkLock.unlock()
        guard let link else { return }
        link.disconnect()
        link.notifyClosed()
    }

    // MARK: - Network path monitoring

    /// Rebuild discovery when connectivity returns or the interface set
    /// changes (sleep/wake, Wi-Fi switch, dock/undock). A same-interface IP
    /// change is intentionally ignored here — the 5 s broadcast already
    /// re-enumerates addresses, so it self-heals without a full rebuild.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let rebuild = Self.shouldRebuild(
                isSatisfied: path.status == .satisfied,
                signature: Self.pathSignature(path),
                primed: &self.pathMonitorPrimed,
                lastSignature: &self.lastPathSignature
            )
            if rebuild {
                Log.net.notice("Network path changed; rebuilding discovery")
                self.restartDiscovery()
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// Status + the sorted set of available interface names. Two paths with
    /// the same signature need no rebuild; a change (interface up/down,
    /// connectivity returning after sleep) does.
    private static func pathSignature(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        return "\(path.status)|\(interfaces)"
    }

    /// Pure decision for the path monitor, extracted so it's unit-testable
    /// without a live NWPathMonitor (which can't be constructed in tests).
    /// Updates the remembered baseline in place and returns `true` only when
    /// a *change* lands on a *satisfied* path AFTER the first (baseline)
    /// callback — so we never rebuild on the initial state, on an unchanged
    /// path, or while connectivity is gone.
    static func shouldRebuild(
        isSatisfied: Bool,
        signature: String,
        primed: inout Bool,
        lastSignature: inout String
    ) -> Bool {
        guard primed else {
            primed = true
            lastSignature = signature
            return false
        }
        guard signature != lastSignature else { return false }
        lastSignature = signature
        return isSatisfied
    }

    /// Numeric host string for a socket address (`nil` for unix sockets).
    static func hostString(from remote: SocketAddress?) -> String? {
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
        case .unixDomainSocket, nil:
            return nil
        }
    }

    private func isLocalAddress(_ remote: SocketAddress) -> Bool {
        guard let host = Self.hostString(from: remote) else { return false }
        return localAddresses().contains(host)
    }

    /// Look up the peer's IP for an active link, used for opening payload
    /// connections back to the same peer.
    public func peerHost(for deviceId: String) -> String? {
        linkLock.lock()
        let link = linksByDeviceId[deviceId]
        linkLock.unlock()
        return Self.hostString(from: link?.activeChannel.remoteAddress)
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
            let oldChannel = existing.replaceChannel(with: channel)
            if let oldChannel {
                channelToDeviceId.removeValue(forKey: ObjectIdentifier(oldChannel))
            }
            channelToDeviceId[ObjectIdentifier(channel)] = identity.deviceId
            linkLock.unlock()
            // Close the superseded channel OUTSIDE linkLock. NIO can run this
            // close synchronously, firing channelInactive -> onClose ->
            // handleClosed on this thread; handleClosed takes linkLock, so
            // closing while we still held it self-deadlocked the discovery
            // queue (every peer reconnect race froze discovery on both Macs,
            // surfacing as the app silently finding no devices). The old
            // channel's deviceId mapping is already removed above, so
            // handleClosed no-ops for it.
            oldChannel?.close(promise: nil)
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
        // Successful handshake clears any prior dial-cooldown.
        dialCooldown.clear(deviceId: deviceId)
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
        let wasSecure = link?.isSecure ?? false
        if isActive {
            linksByDeviceId.removeValue(forKey: deviceId)
        }
        linkLock.unlock()
        // If the channel closed BEFORE TLS completed (peer drops the
        // socket mid-handshake — e.g. our cert is rejected), apply a
        // backoff so we don't dial again on the very next discovery
        // tick. Securely-attached links that close are normal lifecycle
        // events and don't get penalised.
        if isActive, !wasSecure {
            recordDialFailure(deviceId: deviceId)
        }
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
        udpGeneration += 1
        let generation = udpGeneration
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
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.udpRebindAttempts = 0
            case .failed(let err):
                // Not just log-and-die: a rebuild's fresh listener races
                // the dying one for the port because NWListener.cancel()
                // unbinds asynchronously, and losing that race
                // (EADDRINUSE) used to leave UDP discovery receive dead
                // until the next rebuild — peers kept announcing while we
                // were deaf, the exact "two Macs can't find each other
                // until I hit refresh" state. Retry until the port frees.
                Log.net.error("UDP listener failed: \(err.localizedDescription, privacy: .public)")
                self?.scheduleUDPRebind(generation: generation)
            default:
                break
            }
        }
        listener.start(queue: queue)
        udpListener = listener
        Log.net
            .info(
                "UDP listener on \(Settings.udpPort, privacy: .public) (also advertising \(Self.bonjourServiceType, privacy: .public))"
            )
    }

    /// Delay before the next UDP rebind attempt. The first retry is fast
    /// because the common failure is transient: the just-cancelled
    /// listener releases the port within ~100 ms. Later attempts back
    /// off in case something else owns the port (another KDE Connect
    /// client on this Mac), capping so a permanently occupied port
    /// produces bounded log noise while still self-healing the moment
    /// it frees.
    static func udpRebindDelay(attempt: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [0.5, 1, 2, 5, 10]
        guard attempt >= 1 else { return schedule[0] }
        return attempt <= schedule.count ? schedule[attempt - 1] : 30
    }

    /// Schedule a UDP listener rebind after a bind failure. `generation`
    /// pins the incarnation the failure belongs to — teardown, rebuild,
    /// and stop all advance `udpGeneration`, so a stale retry no-ops
    /// instead of binding a second listener behind the current one.
    /// Runs on `queue`.
    private func scheduleUDPRebind(generation: Int) {
        udpRebindAttempts += 1
        let delay = Self.udpRebindDelay(attempt: udpRebindAttempts)
        Log.net
            .notice(
                "Scheduling UDP listener rebind attempt \(self.udpRebindAttempts, privacy: .public) in \(delay, privacy: .public)s"
            )
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.didStart, generation == self.udpGeneration else { return }
            // Drop the failed listener before rebinding; detach its state
            // handler first so its cancellation can't re-enter here.
            self.udpListener?.stateUpdateHandler = nil
            self.udpListener?.cancel()
            self.udpListener = nil
            do {
                try self.startUDPListener()
            } catch {
                Log.net.error("UDP listener rebind failed: \(error.localizedDescription, privacy: .public)")
                self.scheduleUDPRebind(generation: self.udpGeneration)
            }
        }
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

    /// Internal (not private) and with an injectable `now` so the in-process
    /// regression harness can feed synthetic announcements and control the
    /// freshness clock; production callers use the defaults.
    func handleUDPIdentity(_ data: Data, from endpoint: NWEndpoint, now: Date = Date()) {
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
        if localAddresses().contains(hostStr) {
            Log.net.debug("Ignoring UDP identity from local address \(hostStr, privacy: .public)")
            return
        }
        Log.net.debug("UDP identity from \(identity.deviceName, privacy: .public)")

        recordAnnouncement(identity: identity, host: hostStr, port: UInt16(port), now: now)

        // Avoid double-connecting if we already have a secured link —
        // unless the peer now announces from an address our link doesn't
        // point at AND the link's own address has stopped announcing.
        // That means the peer moved (new DHCP lease, band switch) and the
        // link is stale; the old guard kept it until a timeout, so the
        // returning peer stayed unreachable for minutes. A multi-homed
        // peer keeps announcing from every interface, so its link's host
        // stays fresh and it is never flapped here. Also honour the
        // per-peer dial cooldown — without it a peer whose TLS handshake
        // keeps failing gets redialed every 5 s for as long as it
        // broadcasts.
        linkLock.lock()
        let existing = linksByDeviceId[identity.deviceId]
        let canDial = dialCooldown.canDial(deviceId: identity.deviceId)
        let linkHost = Self.hostString(from: existing?.activeChannel.remoteAddress)
        let linkHostLastSeen = linkHost.flatMap { announcements[identity.deviceId]?.hostsLastSeen[$0] }
        linkLock.unlock()
        if let existing, existing.isSecure {
            guard Self.isLinkHostStale(
                linkHost: linkHost, announcedHost: hostStr,
                linkHostLastAnnounce: linkHostLastSeen, now: now,
                quietAfter: Self.announceQuietThreshold
            ) else { return }
            Log.net
                .notice(
                    "\(identity.deviceName, privacy: .public) now announces from \(hostStr, privacy: .public) but the link points at \(linkHost ?? "?", privacy: .public), which went quiet; dropping stale link and re-dialing"
                )
            // Clears the dial cooldown too, so the dial below is allowed.
            dropLinkOnQueue(deviceId: identity.deviceId)
        } else if !canDial {
            return
        }

        dialOnQueue(identity: identity, host: hostStr, port: UInt16(port))
    }

    /// Whether a secured link should be treated as stale because the peer
    /// now announces from a different address. True only when the link's
    /// own address has also stopped announcing (the peer moved). A
    /// multi-homed peer announces from every interface, which keeps the
    /// link's address fresh, so it is never flapped. Conservative on
    /// missing data: if the link's address has never announced (e.g. the
    /// peer connected inbound and its broadcasts don't reach us), the
    /// link is left alone and the liveness reconciler stays the backstop.
    static func isLinkHostStale(
        linkHost: String?,
        announcedHost: String,
        linkHostLastAnnounce: Date?,
        now: Date,
        quietAfter: TimeInterval
    ) -> Bool {
        guard let linkHost, linkHost != announcedHost else { return false }
        guard let linkHostLastAnnounce else { return false }
        return now.timeIntervalSince(linkHostLastAnnounce) > quietAfter
    }

    /// Open a TCP connection to an announced peer and register the
    /// resulting channel through the normal `handleIdentity` flow (which
    /// replaces the channel on an existing link, or creates a new link).
    /// Runs on `queue`.
    private func dialOnQueue(identity: IdentityPayload, host: String, port: UInt16) {
        Log.net
            .info(
                "Connecting to \(identity.deviceName, privacy: .public) at \(host, privacy: .public):\(port, privacy: .public)"
            )

        let future = NIOTransport.shared.connect(
            host: host,
            port: port,
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
        future.whenFailure { [weak self] err in
            Log.net
                .error(
                    "Outbound connect failed to \(host, privacy: .public): \(err.localizedDescription, privacy: .public)"
                )
            // TCP-level failure (host unreachable, refused) deserves the
            // same backoff as a pre-TLS close — without this, an
            // unreachable IPv6 link-local peer redials every 5 s.
            self?.recordDialFailure(deviceId: identity.deviceId)
        }
    }

    /// Record a validated identity announcement: the latest address/port
    /// to re-dial, plus per-host freshness for the multi-homed check.
    /// Prunes long-departed peers and long-quiet hosts on the way.
    private func recordAnnouncement(identity: IdentityPayload, host: String, port: UInt16, now: Date) {
        linkLock.lock()
        defer { linkLock.unlock() }
        var hosts = announcements[identity.deviceId]?.hostsLastSeen ?? [:]
        hosts[host] = now
        hosts = hosts.filter { now.timeIntervalSince($0.value) <= Self.announcementMaxAge }
        announcements[identity.deviceId] = Announcement(
            identity: identity, host: host, port: port, at: now, hostsLastSeen: hosts
        )
        announcements = announcements.filter { now.timeIntervalSince($0.value.at) <= Self.announcementMaxAge }
    }

    /// When this device last announced itself over UDP (any address).
    /// Used by the liveness reconciler to tell "peer left" from "peer is
    /// alive but the link went quiet".
    public func lastAnnounce(deviceId: String) -> Date? {
        linkLock.lock()
        defer { linkLock.unlock() }
        return announcements[deviceId]?.at
    }

    /// Re-dial a peer whose TCP link has been silent past the liveness
    /// hard TTL while its UDP announcements keep arriving: the peer is
    /// alive but the link is suspect (silent vanish and return, half-open
    /// socket). Dialing the announced address replaces the existing
    /// link's channel via the normal `handleIdentity` path on success —
    /// the device is never marked offline in between. No-ops without a
    /// fresh announcement or while the dial cooldown is active.
    public func redialQuietLink(deviceId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.linkLock.lock()
            let announcement = self.announcements[deviceId]
            let canDial = self.dialCooldown.canDial(deviceId: deviceId)
            self.linkLock.unlock()
            guard let announcement, canDial,
                  Date().timeIntervalSince(announcement.at) <= Self.announceQuietThreshold
            else { return }
            self.dialOnQueue(
                identity: announcement.identity,
                host: announcement.host,
                port: announcement.port
            )
        }
    }

    /// Bump the per-peer dial-failure counter and push out the next
    /// allowed dial time. Shared between the TCP-failure and pre-TLS
    /// close paths.
    ///
    /// **Stale-failure guard.** Both call sites can fire after a
    /// concurrent dial for the same peer has already secured a link:
    /// in `handleClosed` between releasing the lock and reaching the
    /// failure path, and in the outbound-connect `whenFailure` callback
    /// for an older dial whose newer sibling already succeeded. If
    /// there's a current secure link we treat this failure as stale
    /// and skip the bump — bumping would re-introduce backoff against
    /// a peer we just established a healthy connection to.
    private func recordDialFailure(deviceId: String) {
        linkLock.lock()
        if let existing = linksByDeviceId[deviceId], existing.isSecure {
            linkLock.unlock()
            Log.net
                .debug(
                    "Skipping stale dial-failure bump for \(deviceId, privacy: .public); secure link exists"
                )
            return
        }
        dialCooldown.recordFailure(deviceId: deviceId)
        let count = dialCooldown.failureCount(deviceId: deviceId)
        linkLock.unlock()
        Log.net
            .notice(
                "Dial failure #\(count, privacy: .public) for \(deviceId, privacy: .public); backing off"
            )
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
