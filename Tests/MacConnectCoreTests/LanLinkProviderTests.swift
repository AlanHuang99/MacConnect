@testable import MacConnectCore
import NIOEmbedded
import XCTest

final class LanLinkProviderTests: XCTestCase {
    func testDuplicateIdentityStaysPendingUntilTLSCompletes() throws {
        let provider = LanLinkProvider()
        let identity = Self.makeIdentity(deviceId: "test-link-\(UUID().uuidString)")
        let active = EmbeddedChannel()
        let candidate = EmbeddedChannel()
        defer {
            _ = try? active.finish()
            _ = try? candidate.finish()
        }

        provider.handleIdentity(identity, channel: active)
        provider.handleSecured(channel: active)
        let link = try XCTUnwrap(provider.debugLink(for: identity.deviceId))
        XCTAssertTrue(link.isSecure)
        XCTAssertTrue(link.activeChannel === active)

        provider.handleIdentity(identity, channel: candidate)

        XCTAssertEqual(provider.debugSnapshot().pendingDeviceIds, Set([identity.deviceId]))
        XCTAssertTrue(link.isSecure)
        XCTAssertTrue(link.activeChannel === active, "The secure link must remain active while replacement TLS is pending")
    }

    func testPendingCandidateCloseDoesNotDetachSecureLink() throws {
        let provider = LanLinkProvider()
        let identity = Self.makeIdentity(deviceId: "test-pending-close-\(UUID().uuidString)")
        let active = EmbeddedChannel()
        let candidate = EmbeddedChannel()
        defer {
            _ = try? active.finish()
            _ = try? candidate.finish()
        }

        provider.handleIdentity(identity, channel: active)
        provider.handleSecured(channel: active)
        let link = try XCTUnwrap(provider.debugLink(for: identity.deviceId))
        provider.handleIdentity(identity, channel: candidate)

        provider.handleClosed(channel: candidate)

        let snapshot = provider.debugSnapshot()
        XCTAssertEqual(snapshot.activeDeviceIds, Set([identity.deviceId]))
        XCTAssertTrue(snapshot.pendingDeviceIds.isEmpty)
        XCTAssertTrue(link.isSecure)
        XCTAssertTrue(link.activeChannel === active)
    }

    func testPendingCandidatePromotesOnlyAfterTLSCompletes() throws {
        let provider = LanLinkProvider()
        let identity = Self.makeIdentity(deviceId: "test-promote-\(UUID().uuidString)")
        let active = EmbeddedChannel()
        let candidate = EmbeddedChannel()
        defer {
            _ = try? active.finish()
            _ = try? candidate.finish()
        }

        provider.handleIdentity(identity, channel: active)
        provider.handleSecured(channel: active)
        let link = try XCTUnwrap(provider.debugLink(for: identity.deviceId))
        provider.handleIdentity(identity, channel: candidate)

        provider.handleSecured(channel: candidate)

        let snapshot = provider.debugSnapshot()
        XCTAssertEqual(snapshot.activeDeviceIds, Set([identity.deviceId]))
        XCTAssertTrue(snapshot.pendingDeviceIds.isEmpty)
        XCTAssertTrue(link.isSecure)
        XCTAssertTrue(link.activeChannel === candidate)
    }

    private static func makeIdentity(deviceId: String) -> IdentityPayload {
        IdentityPayload(
            deviceId: deviceId,
            deviceName: "Test Peer",
            deviceType: .phone,
            protocolVersion: 7,
            tcpPort: nil,
            incomingCapabilities: [],
            outgoingCapabilities: []
        )
    }
}
