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
    private let hardTTL: TimeInterval = 120
    private let maxAge: TimeInterval = 180

    private func action(
        age: TimeInterval, probeable: Bool, announcing: Bool = false
    ) -> DeviceManager.LivenessAction {
        DeviceManager.livenessAction(
            age: age, probeable: probeable, peerAnnouncing: announcing,
            ttl: ttl, quiet: quiet, hardTTL: hardTTL
        )
    }

    func testRecentlyHeardFromIsKept() {
        XCTAssertEqual(action(age: 5, probeable: true), .keep)
    }

    func testQuietLinkIsProbed() {
        XCTAssertEqual(action(age: 20, probeable: true), .probe)
    }

    func testSilentPastTTLIsDropped() {
        XCTAssertEqual(action(age: 75, probeable: true), .drop)
    }

    /// The TTL boundary: exactly at the TTL we still only probe; just past it
    /// we drop. Guards against an off-by-one that would drop live links early.
    func testTTLBoundary() {
        XCTAssertEqual(action(age: ttl, probeable: true), .probe)
        XCTAssertEqual(action(age: ttl + 0.01, probeable: true), .drop)
    }

    /// Below the hard ceiling an un-probeable peer is left alone however the
    /// announcements look: with no probe, ordinary idleness is
    /// indistinguishable from death, and flapping idle links is worse.
    func testUnprobeablePeerKeptUnderHardTTL() {
        XCTAssertEqual(action(age: 75, probeable: false, announcing: true), .keep)
        XCTAssertEqual(action(age: 75, probeable: false, announcing: false), .keep)
        XCTAssertEqual(action(age: hardTTL, probeable: false, announcing: false), .keep)
    }

    /// THE Mac↔Mac regression (0.3.6–0.3.7): an un-probeable peer that also
    /// stopped announcing used to be kept forever, so after a silent vanish
    /// both Macs held mutually stale links and neither ever re-dialed. Past
    /// the hard ceiling it must now be dropped so it shows offline and
    /// reconnects on its next announcement.
    func testUnprobeableSilentPeerIsDroppedPastHardTTL() {
        XCTAssertEqual(action(age: hardTTL + 0.01, probeable: false, announcing: false), .drop)
        XCTAssertEqual(action(age: 3600, probeable: false, announcing: false), .drop)
    }

    /// An un-probeable peer that is TCP-silent past the ceiling but still
    /// announcing over UDP is alive with a suspect link — replace the link in
    /// place rather than flapping the device offline. Healthy idle Mac pairs
    /// exchange no TCP at all, so they land here routinely and must not show
    /// offline blips.
    func testUnprobeableAnnouncingPeerIsRedialedPastHardTTL() {
        XCTAssertEqual(action(age: hardTTL + 0.01, probeable: false, announcing: true), .redial)
        XCTAssertEqual(action(age: 3600, probeable: false, announcing: true), .redial)
    }

    /// Announcements only matter for un-probeable peers: a probeable peer past
    /// its TTL ignored our probe, which is already the death signal —
    /// broadcast reachability must not override it.
    func testAnnouncingDoesNotRescueProbeablePeerPastTTL() {
        XCTAssertEqual(action(age: 75, probeable: true, announcing: true), .drop)
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
    /// probeable -> `livenessAction` defers to the hard-TTL/announcement path.
    func testLimitedClientWithoutBatteryOrMprisHasNoProbes() {
        let probes = DeviceManager.supportedProbes(
            batteryEnabled: true, mprisEnabled: true,
            peerIncoming: [], peerOutgoing: []
        )
        XCTAssertTrue(probes.isEmpty)
    }

    /// Two MacConnects advertise battery and mpris as receivers on BOTH
    /// ends (`incoming = [battery]`, `outgoing = [battery.request]`, same
    /// shape for mpris), so from either side the peer neither accepts a
    /// `*.request` nor produces the state packet — no silent probe exists.
    /// This is what made Mac↔Mac pairs invisible to the 0.3.6 reconciler
    /// and is why `livenessAction` needs the hard-TTL/announcement path at
    /// all. Uses the real capability sets from BatteryPlugin / MprisPlugin /
    /// PingPlugin so a future capability change re-evaluates this test.
    func testMacConnectSymmetricPeerHasNoProbes() {
        let probes = DeviceManager.supportedProbes(
            batteryEnabled: true, mprisEnabled: true,
            peerIncoming: [
                PacketType.battery, PacketType.mpris, PacketType.ping, PacketType.clipboard
            ],
            peerOutgoing: [
                PacketType.batteryRequest, PacketType.mprisRequest, PacketType.ping,
                PacketType.clipboard
            ]
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
