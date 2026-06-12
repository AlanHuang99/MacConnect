@testable import MacConnectCore
import XCTest

/// Pins down the path-monitor rebuild decision that drives sleep/wake and
/// Wi-Fi-change recovery. The bug being prevented: discovery dying after the
/// Mac sleeps and only coming back on an app restart. The decision must
/// rebuild on connectivity returning / interfaces changing, but never on the
/// initial baseline, an unchanged path, or a loss of connectivity.
final class PathRebuildTests: XCTestCase {
    /// The very first callback is the baseline state discovery was already
    /// built for — it records the signature without asking for a rebuild.
    func testFirstCallbackPrimesWithoutRebuild() {
        var primed = false
        var last = ""
        let rebuild = LanLinkProvider.shouldRebuild(
            isSatisfied: true, signature: "satisfied|en0",
            primed: &primed, lastSignature: &last
        )
        XCTAssertFalse(rebuild)
        XCTAssertTrue(primed)
        XCTAssertEqual(last, "satisfied|en0")
    }

    /// An identical path delivered again (NWPathMonitor can repeat) is a no-op.
    func testUnchangedPathDoesNotRebuild() {
        var primed = false
        var last = ""
        _ = LanLinkProvider.shouldRebuild(
            isSatisfied: true, signature: "satisfied|en0", primed: &primed, lastSignature: &last
        )
        let rebuild = LanLinkProvider.shouldRebuild(
            isSatisfied: true, signature: "satisfied|en0", primed: &primed, lastSignature: &last
        )
        XCTAssertFalse(rebuild)
    }

    /// The interface set changing while satisfied (e.g. Wi-Fi switch, dock)
    /// is exactly the event that needs a rebuild.
    func testInterfaceChangeRebuilds() {
        var primed = false
        var last = ""
        _ = LanLinkProvider.shouldRebuild(
            isSatisfied: true, signature: "satisfied|en0", primed: &primed, lastSignature: &last
        )
        let rebuild = LanLinkProvider.shouldRebuild(
            isSatisfied: true, signature: "satisfied|en1", primed: &primed, lastSignature: &last
        )
        XCTAssertTrue(rebuild)
        XCTAssertEqual(last, "satisfied|en1")
    }

    /// Connectivity going away (sleep, Wi-Fi drop) is a change, but there's
    /// nothing to rebuild onto yet — wait for it to come back.
    func testLosingConnectivityDoesNotRebuild() {
        var primed = false
        var last = ""
        _ = LanLinkProvider.shouldRebuild(
            isSatisfied: true, signature: "satisfied|en0", primed: &primed, lastSignature: &last
        )
        let rebuild = LanLinkProvider.shouldRebuild(
            isSatisfied: false, signature: "unsatisfied|", primed: &primed, lastSignature: &last
        )
        XCTAssertFalse(rebuild)
        // …but the new state is remembered, so the bounce back rebuilds.
        XCTAssertEqual(last, "unsatisfied|")
    }

    /// The canonical sleep→wake sequence: satisfied baseline, drop to
    /// unsatisfied on sleep, return to satisfied on wake → exactly one rebuild.
    func testSleepWakeSequenceRebuildsOnceOnWake() {
        var primed = false
        var last = ""
        var rebuilds = 0
        let steps: [(Bool, String)] = [
            (true, "satisfied|en0"), // baseline at launch
            (false, "unsatisfied|"), // sleep
            (true, "satisfied|en0") // wake
        ]
        for (satisfied, sig) in steps where LanLinkProvider.shouldRebuild(
            isSatisfied: satisfied, signature: sig, primed: &primed, lastSignature: &last
        ) {
            rebuilds += 1
        }
        XCTAssertEqual(rebuilds, 1)
    }
}
