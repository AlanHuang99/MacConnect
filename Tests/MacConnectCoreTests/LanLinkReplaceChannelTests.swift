@testable import MacConnectCore
import NIOCore
import NIOEmbedded
import XCTest

/// Pins `LanLink.replaceChannel`'s contract after the deadlock fix.
///
/// `replaceChannel` must hand the superseded channel back to the caller and
/// must NOT close it inline. Closing inline runs synchronously on the calling
/// event-loop thread, firing `channelInactive` → `onClose` →
/// `LanLinkProvider.handleClosed`, which takes the same non-recursive
/// `linkLock` that `handleIdentity` is still holding — a self-deadlock that
/// froze the entire discovery queue and made the app silently find no devices
/// after a peer reconnect race. These tests guard against re-introducing the
/// inline close.
final class LanLinkReplaceChannelTests: XCTestCase {
    private func makeActiveChannel() throws -> EmbeddedChannel {
        let ch = EmbeddedChannel()
        try ch.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1716)).wait()
        return ch
    }

    func testReplaceChannelReturnsOldWithoutClosingIt() throws {
        let chA = try makeActiveChannel()
        let chB = try makeActiveChannel()
        let link = LanLink(deviceId: "dev1", channel: chA, onPacket: { _ in }, onClose: {})
        link.isSecure = true

        let returned = link.replaceChannel(with: chB)

        XCTAssertTrue(returned === chA, "must return the superseded channel for the caller to close")
        XCTAssertTrue(chA.isActive, "old channel must NOT be closed inline (closing inline self-deadlocks)")
        XCTAssertTrue(link.activeChannel === chB, "active channel should now be the replacement")
        XCTAssertFalse(link.isSecure, "isSecure must reset until the new channel completes TLS")

        _ = try? chA.finish()
        _ = try? chB.finish()
    }

    func testReplaceWithSameChannelReturnsNil() throws {
        let chA = try makeActiveChannel()
        let link = LanLink(deviceId: "dev1", channel: chA, onPacket: { _ in }, onClose: {})

        XCTAssertNil(link.replaceChannel(with: chA), "replacing with the same channel is a no-op")
        XCTAssertTrue(chA.isActive)

        _ = try? chA.finish()
    }
}
