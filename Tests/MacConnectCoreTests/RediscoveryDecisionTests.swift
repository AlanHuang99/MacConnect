@testable import MacConnectCore
import XCTest

/// Pins the pure decisions behind the 0.3.8 rediscovery fixes: when a
/// secured link is stale because the peer moved address, and how the UDP
/// listener rebind backoff paces itself after a lost bind race. Both were
/// live-diagnosed failure modes behind "two Macs can't find each other
/// until I hit refresh".
final class RediscoveryDecisionTests: XCTestCase {
    private let quiet = LanLinkProvider.announceQuietThreshold
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - isLinkHostStale (peer moved vs multi-homed)

    /// The new-IP case: the peer announces from a new address and its old
    /// one went quiet — the link is stale and must be dropped + re-dialed.
    func testMovedPeerWithQuietOldHostIsStale() {
        XCTAssertTrue(
            LanLinkProvider.isLinkHostStale(
                linkHost: "192.168.1.10", announcedHost: "192.168.1.99",
                linkHostLastAnnounce: now.addingTimeInterval(-quiet - 1),
                now: now, quietAfter: quiet
            )
        )
    }

    /// A multi-homed peer (Ethernet + Wi-Fi) announces from every interface,
    /// so the link's address stays fresh — flapping a healthy link on every
    /// other-interface broadcast would re-handshake TLS every 5 s.
    func testMultiHomedPeerWithFreshLinkHostIsNotStale() {
        XCTAssertFalse(
            LanLinkProvider.isLinkHostStale(
                linkHost: "192.168.1.10", announcedHost: "192.168.1.99",
                linkHostLastAnnounce: now.addingTimeInterval(-5),
                now: now, quietAfter: quiet
            )
        )
    }

    func testSameHostIsNeverStale() {
        XCTAssertFalse(
            LanLinkProvider.isLinkHostStale(
                linkHost: "192.168.1.10", announcedHost: "192.168.1.10",
                linkHostLastAnnounce: nil,
                now: now, quietAfter: quiet
            )
        )
    }

    /// Conservative on missing data: a link whose address never announced
    /// (inbound connect from a peer whose broadcasts don't reach us) is left
    /// alone — the liveness reconciler is the backstop for those.
    func testLinkHostThatNeverAnnouncedIsNotStale() {
        XCTAssertFalse(
            LanLinkProvider.isLinkHostStale(
                linkHost: "192.168.1.10", announcedHost: "192.168.1.99",
                linkHostLastAnnounce: nil,
                now: now, quietAfter: quiet
            )
        )
    }

    func testUnknownLinkHostIsNotStale() {
        XCTAssertFalse(
            LanLinkProvider.isLinkHostStale(
                linkHost: nil, announcedHost: "192.168.1.99",
                linkHostLastAnnounce: nil,
                now: now, quietAfter: quiet
            )
        )
    }

    // MARK: - UDP rebind backoff

    /// First retry is fast — the common failure is EADDRINUSE against the
    /// just-cancelled listener, which frees its port within ~100 ms — and
    /// later retries back off to a bounded cap so a permanently occupied
    /// port produces bounded log noise while still self-healing.
    func testRebindDelayScheduleAndCap() {
        XCTAssertEqual(LanLinkProvider.udpRebindDelay(attempt: 1), 0.5)
        XCTAssertEqual(LanLinkProvider.udpRebindDelay(attempt: 2), 1)
        XCTAssertEqual(LanLinkProvider.udpRebindDelay(attempt: 3), 2)
        XCTAssertEqual(LanLinkProvider.udpRebindDelay(attempt: 4), 5)
        XCTAssertEqual(LanLinkProvider.udpRebindDelay(attempt: 5), 10)
        XCTAssertEqual(LanLinkProvider.udpRebindDelay(attempt: 6), 30)
        XCTAssertEqual(LanLinkProvider.udpRebindDelay(attempt: 100), 30)
    }
}
