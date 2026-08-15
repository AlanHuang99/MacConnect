@testable import MacConnectCore
import NIOCore
import NIOEmbedded
import XCTest

/// Pins `LanLink`'s atomic post-TLS promotion contract.
final class LanLinkReplaceChannelTests: XCTestCase {
    private func makeActiveChannel() throws -> EmbeddedChannel {
        let ch = EmbeddedChannel()
        try ch.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1716)).wait()
        return ch
    }

    private func makeLink(channel: Channel) -> LanLink {
        LanLink(deviceId: "dev1", channel: channel, onPacket: { _ in }, onClose: {})
    }

    func testPromotingSecuredCandidateReturnsActiveChannelWithoutClosingIt() throws {
        let current = try makeActiveChannel()
        let candidate = try makeActiveChannel()
        let link = makeLink(channel: current)
        link.isSecure = true

        let previous = link.promoteSecuredChannel(candidate)

        XCTAssertTrue(previous === current)
        XCTAssertTrue(current.isActive, "promotion must leave deferred closure to the provider")
        XCTAssertTrue(link.activeChannel === candidate)
        XCTAssertTrue(link.isSecure)

        _ = try? current.finish()
        _ = try? candidate.finish()
    }

    func testPromotingCurrentChannelMarksFirstDeviceFlowSecure() throws {
        let current = try makeActiveChannel()
        let link = makeLink(channel: current)

        XCTAssertNil(link.promoteSecuredChannel(current))
        XCTAssertTrue(link.activeChannel === current)
        XCTAssertTrue(link.isSecure)

        _ = try? current.finish()
    }

    func testLateSecuredCallbackCannotMarkReplacementInsecure() throws {
        let current = try makeActiveChannel()
        let candidate = try makeActiveChannel()
        let link = makeLink(channel: current)

        _ = link.promoteSecuredChannel(candidate)
        XCTAssertFalse(link.markSecured(channel: current))
        XCTAssertTrue(link.activeChannel === candidate)
        XCTAssertTrue(link.isSecure)

        _ = try? current.finish()
        _ = try? candidate.finish()
    }
}
