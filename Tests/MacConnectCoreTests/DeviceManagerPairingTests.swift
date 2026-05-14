@testable import MacConnectCore
import XCTest

/// Pins the idempotent pair-handling contract that prevents the
/// "iPad keeps re-prompting Accept?" loop.
///
/// Note: DeviceManager is a `@MainActor` singleton. We exercise the
/// real one here but isolate state via a unique deviceId per test
/// case so parallel tests don't collide.
@MainActor
final class DeviceManagerPairingTests: XCTestCase {
    func testAlreadyPairedPeerSendingPairTrueIsIgnored() {
        let identity = Self.makeIdentity(deviceId: "test-already-paired-\(UUID().uuidString)")
        let device = DeviceManager.shared.upsert(identity: identity)
        device.isPaired = true
        device.incomingPairRequest = false

        // The iPad / a re-cycled peer fires another pair=true. Pre-fix
        // this flipped incomingPairRequest=true and re-prompted the
        // user. Post-fix it's a no-op against the user-facing flags.
        DeviceManager.shared.didReceivePairPacket(accept: true, device: device)

        XCTAssertTrue(device.isPaired, "Trusted device should stay trusted")
        XCTAssertFalse(device.incomingPairRequest, "Must not re-prompt the user")
        XCTAssertFalse(device.outgoingPairRequest)
    }

    func testIncomingPairRequestOnUnpairedDeviceFlipsTheFlag() {
        let identity = Self.makeIdentity(deviceId: "test-incoming-\(UUID().uuidString)")
        let device = DeviceManager.shared.upsert(identity: identity)
        device.isPaired = false

        DeviceManager.shared.didReceivePairPacket(accept: true, device: device)

        XCTAssertFalse(device.isPaired, "Acceptance from user is still required")
        XCTAssertTrue(device.incomingPairRequest, "UI should show the Accept prompt")
    }

    func testOutgoingPairRequestAcceptedByPeerMarksTrusted() {
        let identity = Self.makeIdentity(deviceId: "test-outgoing-\(UUID().uuidString)")
        let device = DeviceManager.shared.upsert(identity: identity)
        device.isPaired = false
        device.outgoingPairRequest = true

        DeviceManager.shared.didReceivePairPacket(accept: true, device: device)

        XCTAssertTrue(device.isPaired, "Peer accept should land us in trusted")
        XCTAssertFalse(device.outgoingPairRequest, "Pending flag should clear")
    }

    func testRejectionFromPeerClearsTrust() {
        let identity = Self.makeIdentity(deviceId: "test-reject-\(UUID().uuidString)")
        let device = DeviceManager.shared.upsert(identity: identity)
        device.isPaired = true
        Settings.shared.markTrusted(device.id)

        DeviceManager.shared.didReceivePairPacket(accept: false, device: device)

        XCTAssertFalse(device.isPaired)
        XCTAssertFalse(Settings.shared.isTrusted(device.id))
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
