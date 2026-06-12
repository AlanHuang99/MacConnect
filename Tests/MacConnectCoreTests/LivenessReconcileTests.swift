@testable import MacConnectCore
import XCTest

/// Pins down the liveness reconciliation decisions that replace the old
/// purely event-driven "online" model. The bug being prevented: a peer that
/// vanished during sleep / screen saver / Doze kept showing stale "online" +
/// battery + now-playing because no socket-close, wake, or path event ever
/// fired. The reconciler re-derives reachability from freshness on the wall
/// clock; these tests cover the pure decision and eviction predicates.
final class LivenessReconcileTests: XCTestCase {
    private let ttl: TimeInterval = 60
    private let quiet: TimeInterval = 15
    private let maxAge: TimeInterval = 180

    func testRecentlyHeardFromIsKept() {
        XCTAssertEqual(
            DeviceManager.livenessAction(age: 5, probeable: true, ttl: ttl, quiet: quiet),
            .keep
        )
    }

    func testQuietLinkIsProbed() {
        XCTAssertEqual(
            DeviceManager.livenessAction(age: 20, probeable: true, ttl: ttl, quiet: quiet),
            .probe
        )
    }

    func testSilentPastTTLIsDropped() {
        XCTAssertEqual(
            DeviceManager.livenessAction(age: 75, probeable: true, ttl: ttl, quiet: quiet),
            .drop
        )
    }

    /// Without a probe we can't distinguish a dead link from a genuinely idle
    /// one, so silence alone must never drop the peer — defer to the
    /// link-level mechanisms instead (no regression for un-probeable peers).
    func testUnprobeablePeerIsNeverDroppedOnSilence() {
        XCTAssertEqual(
            DeviceManager.livenessAction(age: 75, probeable: false, ttl: ttl, quiet: quiet),
            .keep
        )
        XCTAssertEqual(
            DeviceManager.livenessAction(age: 20, probeable: false, ttl: ttl, quiet: quiet),
            .keep
        )
    }

    /// The TTL boundary: exactly at the TTL we still only probe; just past it
    /// we drop. Guards against an off-by-one that would drop live links early.
    func testTTLBoundary() {
        XCTAssertEqual(
            DeviceManager.livenessAction(age: ttl, probeable: true, ttl: ttl, quiet: quiet),
            .probe
        )
        XCTAssertEqual(
            DeviceManager.livenessAction(age: ttl + 0.01, probeable: true, ttl: ttl, quiet: quiet),
            .drop
        )
    }

    func testEvictsStaleOfflineUnpairedGhost() {
        XCTAssertTrue(
            DeviceManager.shouldEvictUnpaired(
                isPaired: false, isReachable: false, age: maxAge + 1, maxAge: maxAge
            )
        )
    }

    func testKeepsReachableUnpairedDevice() {
        // A discoverable, currently-connected unpaired device must stay in the
        // list however long it's been quiet — you still need to see it to pair.
        XCTAssertFalse(
            DeviceManager.shouldEvictUnpaired(
                isPaired: false, isReachable: true, age: 10000, maxAge: maxAge
            )
        )
    }

    func testNeverEvictsPairedDevice() {
        // Paired peers stay so "last seen 4h ago" remains visible.
        XCTAssertFalse(
            DeviceManager.shouldEvictUnpaired(
                isPaired: true, isReachable: false, age: 10000, maxAge: maxAge
            )
        )
    }

    /// The Codex review case: a paired but limited client that advertises
    /// neither battery nor mpris must yield no probes — otherwise we'd probe it
    /// with packets it ignores and `.drop` it every TTL. No probes -> not
    /// probeable -> `livenessAction` keeps it (deferring to link-level checks).
    func testLimitedClientWithoutBatteryOrMprisHasNoProbes() {
        let probes = DeviceManager.supportedProbes(
            batteryEnabled: true, mprisEnabled: true,
            peerIncoming: [], peerOutgoing: []
        )
        XCTAssertTrue(probes.isEmpty)
    }

    func testPeerAcceptingTheRequestIsProbeable() {
        let probes = DeviceManager.supportedProbes(
            batteryEnabled: true, mprisEnabled: true,
            peerIncoming: [PacketType.batteryRequest], peerOutgoing: []
        )
        XCTAssertEqual(probes, [.battery])
    }

    /// A peer that only advertises the producer side (it sends battery state)
    /// will still answer our request, so that counts too.
    func testPeerAdvertisingProducerCapabilityIsProbeable() {
        let probes = DeviceManager.supportedProbes(
            batteryEnabled: true, mprisEnabled: false,
            peerIncoming: [], peerOutgoing: [PacketType.battery]
        )
        XCTAssertEqual(probes, [.battery])
    }

    /// A locally disabled plugin is never probed even when the peer supports
    /// it, honouring the per-device mute.
    func testLocallyDisabledPluginIsNotProbed() {
        let probes = DeviceManager.supportedProbes(
            batteryEnabled: false, mprisEnabled: true,
            peerIncoming: [PacketType.batteryRequest, PacketType.mprisRequest], peerOutgoing: []
        )
        XCTAssertEqual(probes, [.mpris])
    }
}
