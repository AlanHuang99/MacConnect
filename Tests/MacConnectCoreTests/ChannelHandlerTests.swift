import XCTest
import NIOCore
import NIOEmbedded
import NIOSSL
@testable import MacConnectCore

/// EmbeddedChannel tests for `KDEConnectChannelHandler`'s pre-TLS state
/// machine. These do not drive the TLS handshake itself (that would require
/// two channels piped together); they verify the plain-identity parse,
/// state transitions, and the read-buffer overflow protection added in A4.
final class ChannelHandlerTests: XCTestCase {
    private var tempDir: URL!
    private var sslContext: NIOSSLContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("macconnect-handler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let service = CertificateService(rootDirectory: tempDir)
        try service.generateIdentity(forDeviceId: "test_handler")
        let certs = try NIOSSLCertificate.fromPEMFile(service.certificatePEMURL.path)
        let key = try NIOSSLPrivateKey(file: service.privateKeyPEMURL.path, format: .pem)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        config.certificateVerification = .none
        config.minimumTLSVersion = .tlsv12
        sslContext = try NIOSSLContext(configuration: config)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// Class wrapper so the test's `@Sendable` `onIdentity` closure can
    /// store the parsed identity without mutating a captured var (which
    /// strict-concurrency rejects). Reference write to the class is fine.
    final class IdentityCapture: @unchecked Sendable {
        var value: IdentityPayload?
    }

    func testInboundIdentityIsParsedAndForwarded() throws {
        let received = IdentityCapture()
        let handler = KDEConnectChannelHandler(
            role: .inbound,
            sslContext: sslContext,
            onIdentity: { id, _ in received.value = id },
            onPacket: { _ in },
            onSecured: { },
            onClose: { _ in }
        )
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }

        let id = IdentityPayload(
            deviceId: "peer_xyz",
            deviceName: "Peer XYZ",
            deviceType: .laptop,
            protocolVersion: 7,
            tcpPort: 1716,
            incomingCapabilities: [PacketType.ping],
            outgoingCapabilities: [PacketType.ping]
        )
        let data = try id.toPacket().serialized()
        var buf = channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        // writeInbound may throw if the subsequent TLS-handler install
        // bumps the channel inactive (EmbeddedChannel's pipeline support
        // for position:.first inserts is limited). The asserts that matter
        // are pre-TLS: the identity callback fired with the right data.
        _ = try? channel.writeInbound(buf)

        XCTAssertEqual(received.value?.deviceId, "peer_xyz")
        XCTAssertEqual(received.value?.deviceName, "Peer XYZ")
    }

    func testIdentityOverflowClosesChannel() throws {
        let handler = KDEConnectChannelHandler(
            role: .inbound,
            sslContext: sslContext,
            onIdentity: { _, _ in },
            onPacket: { _ in },
            onSecured: { },
            onClose: { _ in }
        )
        let channel = EmbeddedChannel(handler: handler)
        defer { _ = try? channel.finish() }

        // Feed 128 KiB of plain bytes with no newline — twice the
        // plain-identity cap (64 KiB). Handler must close the channel.
        let blob = [UInt8](repeating: 0x41, count: 128 * 1024)
        var buf = channel.allocator.buffer(capacity: blob.count)
        buf.writeBytes(blob)
        // writeInbound throws on close; either way the channel must end up
        // inactive.
        do {
            try channel.writeInbound(buf)
        } catch {
            // Channel close from inside the handler can surface as an error
            // here; that is the expected signal of an overflow-triggered
            // close.
        }
        XCTAssertFalse(channel.isActive, "Channel must close on overflow")
    }
}
