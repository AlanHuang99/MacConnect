@testable import MacConnectCore
import Network
import NIOCore
import NIOPosix
import NIOSSL
import XCTest

/// In-process regression harness for the Mac↔Mac rediscovery fixes: a real
/// `LanLinkProvider` (announcement bookkeeping, dial, TLS, link maps,
/// reconciler wiring) runs against a scripted fake KDE Connect peer on
/// loopback TCP. The fake peer plays the protocol's accept side: read the
/// provider's plain identity line, then act as TLS client (the TCP-accept
/// side is the TLS client per the inverted-role protocol), and go silent —
/// which is exactly the shape of the silent-vanish bug.
///
/// What this covers that the pure-decision tests cannot: the full wiring
/// from a UDP announcement through `dialOnQueue` / `handleIdentity` /
/// `handleSecured` into `DeviceManager`, the reconciler's `.redial` path
/// preserving an established secure channel without an offline flap, the
/// `.drop` path
/// tearing the link down and the next announcement re-establishing it, and
/// the stale-host path dropping a link whose address went quiet.
///
/// The provider under test is `LanLinkProvider.shared` (the reconciler
/// resolves it internally), but `start()` is never called: no UDP listener,
/// broadcast, or mDNS runs. Announcements are injected via
/// `handleUDPIdentity` with `localAddressesOverride = []` so loopback
/// traffic isn't rejected as our own.
final class LanLinkHarnessTests: XCTestCase {
    private var fakePeer: FakeKDEConnectPeer!
    private var peerId: String!
    private var provider: LanLinkProvider {
        LanLinkProvider.shared
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        peerId = "HARNESS_PEER_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        fakePeer = try FakeKDEConnectPeer()
        provider.localAddressesOverride = []
    }

    override func tearDownWithError() throws {
        let id = peerId!
        provider.dropLink(deviceId: id)
        // Cleanup stays scoped to this test's own device — no global
        // reconcile pass, and no trusted-devices rewrite (the preferences
        // plist is the one resource genuinely shared across parallel test
        // worker processes; in-memory singletons are per-process, and
        // XCTest runs a class's methods serially within a process).
        MainActor.assumeIsolated {
            DeviceManager.shared.removeDevice(id: id)
        }
        CertificateService.shared.deleteRemoteCert(deviceId: id)
        provider.localAddressesOverride = nil
        fakePeer.shutdown()
        fakePeer = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func peerIdentity() -> IdentityPayload {
        // MacConnect-symmetric receiver caps: un-probeable by design, the
        // exact shape that made two Macs invisible to the 0.3.6 reconciler.
        IdentityPayload(
            deviceId: peerId,
            deviceName: "harness-peer",
            deviceType: .desktop,
            protocolVersion: 7,
            tcpPort: Int(fakePeer.port),
            incomingCapabilities: [PacketType.battery, PacketType.mpris, PacketType.ping],
            outgoingCapabilities: [PacketType.batteryRequest, PacketType.mprisRequest, PacketType.ping]
        )
    }

    /// Inject a UDP identity announcement as if it arrived from `host`.
    private func announce(from host: String = "127.0.0.1", now: Date = Date()) throws {
        let data = try peerIdentity().toPacket().serialized()
        provider.handleUDPIdentity(
            data,
            from: .hostPort(host: NWEndpoint.Host(host), port: 45678),
            now: now
        )
    }

    /// Poll until the condition holds, pumping the main actor between
    /// checks so the provider's `Task { @MainActor … }` hops can land.
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 8, _ what: String, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(what)")
    }

    @MainActor
    private func device() -> Device? {
        DeviceManager.shared.devices[peerId]
    }

    @MainActor
    private func establishLink() async throws {
        try announce()
        try await waitUntil("initial link to secure") {
            self.device()?.isReachable == true && self.device()?.link?.isSecure == true
        }
        // Pair the device object directly instead of Settings.markTrusted:
        // the reconciler gates on `device.isPaired`, and the trusted-devices
        // default is a single shared plist key that parallel test workers
        // would race on. Nothing in the outbound-dial path re-reads trust.
        device()?.isPaired = true
        XCTAssertEqual(fakePeer.connectionsAccepted, 1)
    }

    // MARK: - Tests

    /// THE regression: a paired, un-probeable peer whose TCP link went
    /// silent past the hard TTL while it kept announcing must get its link
    /// re-dialed without replacing an established secure channel: device
    /// never flaps offline, and the peer sees a fresh connection. Before the
    /// fix the reconciler returned `.keep` forever and nothing ever re-dialed.
    @MainActor
    func testQuietLinkToAnnouncingPeerIsRedialedInPlace() async throws {
        try await establishLink()
        let oldChannel = try XCTUnwrap(device()?.link?.activeChannel)

        // The peer stays TCP-silent but keeps announcing. Advance the
        // reconciler's clock past the hard TTL; the fresh announcement is
        // stamped with the same shifted clock so it still counts as live.
        let shifted = Date().addingTimeInterval(DeviceManager.unprobeableLivenessTTL + 1)
        try announce(now: shifted)
        DeviceManager.shared.reconcile(now: shifted)

        try await waitUntil("re-dial to preserve the secure channel") {
            self.fakePeer.connectionsAccepted == 2
                && self.device()?.link?.isSecure == true
                && self.device()?.link?.activeChannel === oldChannel
        }
        XCTAssertEqual(
            device()?.isReachable, true,
            "an announcing peer must never flap offline during the in-place re-dial"
        )
    }

    /// A paired, un-probeable peer that stopped announcing too is really
    /// gone: past the hard TTL the link is dropped and the device marked
    /// offline — and its next announcement re-establishes the link (the
    /// full vanish → offline → return → reconnect loop that used to
    /// require a manual refresh).
    @MainActor
    func testSilentVanishDropsAndNextAnnouncementReconnects() async throws {
        try await establishLink()

        // No fresh announcement: both the link and the announcements are
        // stale when the reconciler looks.
        DeviceManager.shared.reconcile(
            now: Date().addingTimeInterval(DeviceManager.unprobeableLivenessTTL + 1)
        )
        try await waitUntil("drop to mark the device offline") {
            self.device()?.isReachable == false && self.provider.peerHost(for: self.peerId) == nil
        }

        // The peer "comes back": one announcement reconnects it. The drop
        // must have cleared the dial cooldown for this to be immediate.
        try announce()
        try await waitUntil("reconnect after the peer returns") {
            self.fakePeer.connectionsAccepted == 2
                && self.device()?.isReachable == true
                && self.device()?.link?.isSecure == true
        }
    }

    /// New-IP case: the peer now announces from a different address and the
    /// link's own address has stopped announcing — the stale link must be
    /// dropped immediately (no waiting out the hard TTL). The redial target
    /// here is unroutable, so only the drop is asserted; the dial itself is
    /// covered by the tests above.
    @MainActor
    func testAnnouncementFromNewHostDropsStaleLink() async throws {
        try await establishLink()

        // Same peer, new source address, and late enough that the link's
        // 127.0.0.1 announcement history counts as quiet (> 30 s).
        let shifted = Date().addingTimeInterval(LanLinkProvider.announceQuietThreshold + 1)
        try announce(from: "203.0.113.9", now: shifted)

        try await waitUntil("stale link to be dropped on host change") {
            self.provider.peerHost(for: self.peerId) == nil && self.device()?.isReachable == false
        }
        XCTAssertEqual(
            fakePeer.connectionsAccepted, 1,
            "the redial goes to the announced (new) host, not back to the old one"
        )
    }

    /// Codex review case on #28: a peer that keeps announcing but refuses
    /// TCP (its app listener died; the suspect link lives on) must not be
    /// re-dialed every reconcile tick with no backoff. The failed re-dial
    /// arms the dial cooldown — recordDialFailure alone can't, because its
    /// stale-failure guard sees the still-"secure" old link and skips the
    /// bump — and the next reconcile pass inside the backoff window stays
    /// quiet. The device meanwhile stays reachable on its old link.
    @MainActor
    func testFailedRedialArmsCooldown() async throws {
        try await establishLink()
        fakePeer.stopAccepting()

        let shifted = Date().addingTimeInterval(DeviceManager.unprobeableLivenessTTL + 1)
        try announce(now: shifted)
        DeviceManager.shared.reconcile(now: shifted)

        try await waitUntil("failed re-dial to arm the cooldown") {
            self.provider.dialFailureCount(deviceId: self.peerId) >= 1
        }
        let armed = provider.dialFailureCount(deviceId: peerId)

        // Within the backoff window another reconcile pass must not dial
        // (and therefore must not bump the failure count again).
        try announce(now: shifted.addingTimeInterval(1))
        DeviceManager.shared.reconcile(now: shifted.addingTimeInterval(1))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            provider.dialFailureCount(deviceId: peerId), armed,
            "a reconcile pass inside the backoff window must not re-dial"
        )
        XCTAssertEqual(fakePeer.connectionsAccepted, 1)
        XCTAssertEqual(device()?.isReachable, true, "the old link stays up while re-dials back off")
    }
}

// MARK: - Fake peer

/// A minimal scripted KDE Connect peer: TCP listener on loopback that
/// accepts, reads the initiator's plain identity line, then upgrades to TLS
/// as the client side (per protocol, the TCP acceptor is the TLS client)
/// presenting its own throwaway self-signed certificate, and then goes
/// quiet. Binds inside 1717...1764 because `handleUDPIdentity` validates
/// announced TCP ports against the KDE Connect range.
private final class FakeKDEConnectPeer: @unchecked Sendable {
    /// NSLock-guarded accept counter, written from the event loop and read
    /// from the test's polling loop.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    let port: UInt16
    private let group: MultiThreadedEventLoopGroup
    private let serverChannel: Channel
    private let tempDir: URL
    private let counter = Counter()

    var connectionsAccepted: Int {
        counter.current
    }

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macconnect-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        let certService = CertificateService(rootDirectory: dir)
        try certService.generateIdentity(forDeviceId: "harness_fake_peer")
        let certs = try NIOSSLCertificate.fromPEMFile(certService.certificatePEMURL.path)
        let key = try NIOSSLPrivateKey(file: certService.privateKeyPEMURL.path, format: .pem)
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateChain = certs.map { .certificate($0) }
        config.privateKey = .privateKey(key)
        config.certificateVerification = .none
        config.minimumTLSVersion = .tlsv12
        let sslContext = try NIOSSLContext(configuration: config)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let counter = counter
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    counter.increment()
                    let handler = FakePeerHandler(sslContext: sslContext)
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }

        // The app under test (or a real MacConnect on this machine) may own
        // 1716; scan the rest of the protocol range for a free port.
        var bound: Channel?
        for candidate in UInt16(1717) ... UInt16(1764) {
            if let ch = try? bootstrap.bind(host: "127.0.0.1", port: Int(candidate)).wait() {
                bound = ch
                break
            }
        }
        guard let bound, let boundPort = bound.localAddress?.port else {
            throw NSError(
                domain: "FakeKDEConnectPeer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no free port in 1717...1764"]
            )
        }
        serverChannel = bound
        port = UInt16(boundPort)
    }

    /// Close only the listener, keeping already-accepted connections (and
    /// the event loop) alive — the shape of a peer whose app-level listener
    /// died while its old TCP link and its announcements live on.
    func stopAccepting() {
        try? serverChannel.close().wait()
    }

    func shutdown() {
        try? serverChannel.close().wait()
        try? group.syncShutdownGracefully()
        try? FileManager.default.removeItem(at: tempDir)
    }
}

/// Accept-side protocol driver for the fake peer: buffer until the plain
/// identity's LF, then install the TLS client handler and replay any
/// leftover bytes through it. Stays silent after the handshake.
private final class FakePeerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let sslContext: NIOSSLContext
    private var buffer = ByteBuffer()
    private var sawIdentity = false

    init(sslContext: NIOSSLContext) {
        self.sslContext = sslContext
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !sawIdentity else {
            context.fireChannelRead(data)
            return
        }
        var inbound = unwrapInboundIn(data)
        buffer.writeBuffer(&inbound)
        guard let lfIndex = buffer.readableBytesView.firstIndex(of: 0x0A) else { return }
        let lineLength = lfIndex - buffer.readerIndex
        _ = buffer.readSlice(length: lineLength)
        _ = buffer.readBytes(length: 1)
        sawIdentity = true
        do {
            let ssl = try NIOSSLClientHandler(
                context: sslContext, serverHostname: nil
            )
            try context.pipeline.syncOperations.addHandler(ssl, position: .first)
            if buffer.readableBytes > 0,
               let leftover = buffer.readSlice(length: buffer.readableBytes)
            {
                context.channel.pipeline.fireChannelRead(leftover)
            }
        } catch {
            context.close(promise: nil)
        }
    }
}
