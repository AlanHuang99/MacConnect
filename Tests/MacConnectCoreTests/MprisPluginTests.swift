@testable import MacConnectCore
import XCTest

@MainActor
final class MprisPluginTests: XCTestCase {
    func testCapabilitiesAdvertiseAndroidControlledDirection() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.incomingCapabilities, [PacketType.mprisRequest])
        XCTAssertEqual(plugin.outgoingCapabilities, [PacketType.mpris])
    }

    func testLocalRequestIsAnsweredAndRemoteStateDoesNotTriggerFollowUp() async {
        let recorder = PacketRecorder()
        let plugin = makePlugin(recorder: recorder)
        let device = makeDevice(id: "phone", incoming: [PacketType.mpris])

        await plugin.handle(packet: .localPlayerListRequest, from: device)

        XCTAssertEqual(
            recorder.packets.last?.body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            ["Mac"]
        )

        let sentBeforeRemoteState = recorder.packets.count
        await plugin.handle(packet: NetworkPacket(
            type: PacketType.mpris,
            body: ["playerList": .array([.string("Phone Player")])]
        ), from: device)

        XCTAssertEqual(recorder.packets.count, sentBeforeRemoteState)
    }

    func testAttachSendsCurrentPlayerListAndState() async {
        let recorder = PacketRecorder()
        var snapshot = populatedSnapshot
        snapshot.playerName = "IINA"
        let plugin = MprisPlugin(
            localController: FakeLocalMediaController(snapshot: snapshot),
            devices: { [] },
            pluginEnabled: { _ in true },
            sendPacket: recorder.record
        )

        await plugin.attach(to: makeDevice())

        XCTAssertEqual(recorder.packets.count, 2)
        XCTAssertEqual(
            recorder.packets.first?.body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            ["IINA"]
        )
        XCTAssertEqual(recorder.packets.last?.body["player"]?.stringValue, "IINA")
    }

    func testLocalChangeBroadcastsOnlyToEligibleDevice() {
        let enabled = makeDevice(
            id: "enabled",
            paired: true,
            reachable: true,
            incoming: [PacketType.mpris]
        )
        let offline = makeDevice(
            id: "offline",
            paired: true,
            reachable: false,
            incoming: [PacketType.mpris]
        )
        let unpaired = makeDevice(
            id: "unpaired",
            paired: false,
            reachable: true,
            incoming: [PacketType.mpris]
        )
        let incompatible = makeDevice(
            id: "incompatible",
            paired: true,
            reachable: true,
            incoming: []
        )
        let disabled = makeDevice(
            id: "disabled",
            paired: true,
            reachable: true,
            incoming: [PacketType.mpris]
        )
        let recorder = PacketRecorder()
        let fake = FakeLocalMediaController(snapshot: populatedSnapshot)
        let plugin = MprisPlugin(
            localController: fake,
            devices: { [enabled, offline, unpaired, incompatible, disabled] },
            pluginEnabled: { $0 != "disabled" },
            sendPacket: recorder.record
        )

        withExtendedLifetime(plugin) { fake.emitChange() }

        XCTAssertEqual(recorder.deviceIds, ["enabled"])
        XCTAssertEqual(recorder.packets.first?.body["player"]?.stringValue, "Mac")
    }

    func testUnavailableLocalPlayerBroadcastsEmptyPlayerList() {
        let device = makeDevice(
            id: "enabled",
            paired: true,
            reachable: true,
            incoming: [PacketType.mpris]
        )
        let recorder = PacketRecorder()
        let fake = FakeLocalMediaController(snapshot: LocalMediaSnapshot(
            title: nil,
            artist: nil,
            album: nil,
            isPlaying: false,
            transportAvailable: false,
            volume: nil,
            lengthMs: nil,
            positionMs: nil
        ))
        let plugin = MprisPlugin(
            localController: fake,
            devices: { [device] },
            pluginEnabled: { _ in true },
            sendPacket: recorder.record
        )

        withExtendedLifetime(plugin) { fake.emitChange() }

        XCTAssertEqual(
            recorder.packets.first?.body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            []
        )
    }

    func testPlayerApplicationChangeBroadcastsNewListBeforeState() {
        let device = makeDevice(id: "enabled")
        let recorder = PacketRecorder()
        let fake = FakeLocalMediaController(snapshot: populatedSnapshot)
        let plugin = MprisPlugin(
            localController: fake,
            devices: { [device] },
            pluginEnabled: { _ in true },
            sendPacket: recorder.record
        )
        fake.snapshot.playerName = "IINA"

        withExtendedLifetime(plugin) { fake.emitChange() }

        XCTAssertEqual(recorder.packets.count, 2)
        XCTAssertEqual(
            recorder.packets[0].body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            ["IINA"]
        )
        XCTAssertEqual(recorder.packets[1].body["player"]?.stringValue, "IINA")
    }

    func testLocalChangeFansOutStateToEveryEligibleDevice() {
        let first = makeDevice(id: "k60")
        let second = makeDevice(id: "note12")
        let recorder = PacketRecorder()
        let fake = FakeLocalMediaController(snapshot: populatedSnapshot)
        let plugin = MprisPlugin(
            localController: fake,
            devices: { [first, second] },
            pluginEnabled: { _ in true },
            sendPacket: recorder.record
        )

        withExtendedLifetime(plugin) { fake.emitChange() }

        XCTAssertEqual(Set(recorder.deviceIds), ["k60", "note12"])
        XCTAssertTrue(recorder.packets.allSatisfy {
            $0.body["isPlaying"]?.boolValue == true
        })
    }

    private var populatedSnapshot: LocalMediaSnapshot {
        LocalMediaSnapshot(
            title: "Local Track",
            artist: "Local Artist",
            album: nil,
            isPlaying: true,
            transportAvailable: true,
            volume: 35,
            lengthMs: nil,
            positionMs: nil
        )
    }

    private func makePlugin(recorder suppliedRecorder: PacketRecorder? = nil) -> MprisPlugin {
        let recorder = suppliedRecorder ?? PacketRecorder()
        return MprisPlugin(
            localController: FakeLocalMediaController(snapshot: populatedSnapshot),
            devices: { [] },
            pluginEnabled: { _ in true },
            sendPacket: recorder.record
        )
    }

    private func makeDevice(
        id: String = "phone",
        paired: Bool = true,
        reachable: Bool = true,
        incoming: [String] = [PacketType.mpris]
    ) -> Device {
        let device = Device(identity: IdentityPayload(
            deviceId: id,
            deviceName: id,
            deviceType: .phone,
            protocolVersion: 7,
            tcpPort: nil,
            incomingCapabilities: incoming,
            outgoingCapabilities: [PacketType.mprisRequest]
        ), paired: paired)
        device.isReachable = reachable
        return device
    }
}

@MainActor
private final class PacketRecorder {
    private(set) var packets: [NetworkPacket] = []
    private(set) var deviceIds: [String] = []

    func record(_ packet: NetworkPacket, _ device: Device) {
        packets.append(packet)
        deviceIds.append(device.id)
    }
}

private extension NetworkPacket {
    static let localPlayerListRequest = NetworkPacket(
        type: PacketType.mprisRequest,
        body: ["requestPlayerList": .bool(true)]
    )
}
