@testable import MacConnectCore
import XCTest

/// Pins down the per-peer dial-cooldown contract that prevents the
/// "redial every 5 s when TLS keeps failing" loop from coming back.
final class DialCooldownTrackerTests: XCTestCase {
    func testCanDialOnCleanState() {
        let tracker = DialCooldownTracker()
        XCTAssertTrue(tracker.canDial(deviceId: "peer"))
        XCTAssertEqual(tracker.failureCount(deviceId: "peer"), 0)
    }

    func testFailureBlocksDialUntilBackoffElapses() {
        var tracker = DialCooldownTracker()
        let t0 = Date()
        tracker.recordFailure(deviceId: "peer", now: t0)

        XCTAssertFalse(tracker.canDial(deviceId: "peer", now: t0))
        // First-failure backoff is 10 s — still blocked at 9.5 s.
        XCTAssertFalse(tracker.canDial(deviceId: "peer", now: t0.addingTimeInterval(9.5)))
        // Allowed again at 10 s.
        XCTAssertTrue(tracker.canDial(deviceId: "peer", now: t0.addingTimeInterval(10)))
    }

    func testBackoffGrowsAndCaps() throws {
        var tracker = DialCooldownTracker()
        let t0 = Date()
        // Walk the schedule and verify each subsequent wait matches.
        for (idx, expected) in DialCooldownTracker.backoffSeconds.enumerated() {
            tracker.recordFailure(deviceId: "peer", now: t0)
            XCTAssertFalse(
                tracker.canDial(deviceId: "peer", now: t0.addingTimeInterval(expected - 0.5)),
                "Failure \(idx + 1) should still block just before \(expected)s"
            )
            XCTAssertTrue(
                tracker.canDial(deviceId: "peer", now: t0.addingTimeInterval(expected)),
                "Failure \(idx + 1) should clear at \(expected)s"
            )
        }
        // One more failure beyond the schedule should reuse the cap.
        tracker.recordFailure(deviceId: "peer", now: t0)
        let cap = try XCTUnwrap(DialCooldownTracker.backoffSeconds.last)
        XCTAssertFalse(tracker.canDial(deviceId: "peer", now: t0.addingTimeInterval(cap - 0.5)))
        XCTAssertTrue(tracker.canDial(deviceId: "peer", now: t0.addingTimeInterval(cap)))
    }

    func testClearResetsCounterAndAllowsImmediateDial() {
        var tracker = DialCooldownTracker()
        let t0 = Date()
        tracker.recordFailure(deviceId: "peer", now: t0)
        tracker.recordFailure(deviceId: "peer", now: t0)
        XCTAssertEqual(tracker.failureCount(deviceId: "peer"), 2)

        tracker.clear(deviceId: "peer")

        XCTAssertEqual(tracker.failureCount(deviceId: "peer"), 0)
        XCTAssertTrue(tracker.canDial(deviceId: "peer", now: t0))
    }

    func testFailuresAreScopedPerPeer() {
        var tracker = DialCooldownTracker()
        let t0 = Date()
        tracker.recordFailure(deviceId: "iPad", now: t0)

        // The iPad is in cooldown but other peers are unaffected.
        XCTAssertFalse(tracker.canDial(deviceId: "iPad", now: t0))
        XCTAssertTrue(tracker.canDial(deviceId: "Pixel", now: t0))
        XCTAssertEqual(tracker.failureCount(deviceId: "Pixel"), 0)
    }

    func testRemoveAllClearsEveryPeer() {
        var tracker = DialCooldownTracker()
        let t0 = Date()
        tracker.recordFailure(deviceId: "iPad", now: t0)
        tracker.recordFailure(deviceId: "Pixel", now: t0)
        tracker.removeAll()
        XCTAssertTrue(tracker.canDial(deviceId: "iPad", now: t0))
        XCTAssertTrue(tracker.canDial(deviceId: "Pixel", now: t0))
    }
}
