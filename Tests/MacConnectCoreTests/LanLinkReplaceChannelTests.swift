@testable import MacConnectCore
import NIOCore
import NIOEmbedded
import XCTest

/// Pins `LanLink`'s duplicate-channel adoption policy.
final class LanLinkReplaceChannelTests: XCTestCase {
    private func makeActiveChannel() throws -> EmbeddedChannel {
        let ch = EmbeddedChannel()
        try ch.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1716)).wait()
        return ch
    }

    private func makeLink(channel: Channel) -> LanLink {
        LanLink(deviceId: "dev1", channel: channel, onPacket: { _ in }, onClose: {})
    }

    func testSecureActiveLinkRejectsDuplicateCandidate() throws {
        let current = try makeActiveChannel()
        let candidate = try makeActiveChannel()
        let link = makeLink(channel: current)
        link.isSecure = true

        guard case .rejected = link.adoptChannel(candidate) else {
            return XCTFail("secure active link must reject the candidate")
        }
        XCTAssertTrue(link.activeChannel === current)
        XCTAssertTrue(link.isSecure)

        _ = try? current.finish()
        _ = try? candidate.finish()
    }

    func testInsecureLinkAdoptsCandidateAndReturnsCurrentChannel() throws {
        let current = try makeActiveChannel()
        let candidate = try makeActiveChannel()
        let link = makeLink(channel: current)

        guard case .replaced(let previous) = link.adoptChannel(candidate) else {
            return XCTFail("insecure link must adopt the candidate")
        }
        XCTAssertTrue(previous === current)
        XCTAssertTrue(current.isActive, "adoption must not close the previous channel inline")
        XCTAssertTrue(link.activeChannel === candidate)
        XCTAssertFalse(link.isSecure)

        _ = try? current.finish()
        _ = try? candidate.finish()
    }

    func testInactiveSecureLinkAdoptsCandidateAndReturnsCurrentChannel() throws {
        let current = try makeActiveChannel()
        let candidate = try makeActiveChannel()
        let link = makeLink(channel: current)
        link.isSecure = true
        try current.close().wait()

        guard case .replaced(let previous) = link.adoptChannel(candidate) else {
            return XCTFail("inactive link must adopt the candidate even when marked secure")
        }
        XCTAssertTrue(previous === current)
        XCTAssertTrue(link.activeChannel === candidate)
        XCTAssertFalse(link.isSecure)

        _ = try? current.finish()
        _ = try? candidate.finish()
    }
}
