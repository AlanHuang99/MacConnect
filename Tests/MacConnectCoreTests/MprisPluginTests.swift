@testable import MacConnectCore
import XCTest

@MainActor
final class MprisPluginTests: XCTestCase {
    override func tearDown() {
        MprisStore.shared.clear(deviceId: "phone")
        super.tearDown()
    }

    func testCapabilitiesAdvertiseBothControllerAndControlledDirections() {
        let plugin = makePlugin()

        XCTAssertEqual(
            Set(plugin.incomingCapabilities),
            [PacketType.mpris, PacketType.mprisRequest]
        )
        XCTAssertEqual(
            Set(plugin.outgoingCapabilities),
            [PacketType.mprisRequest, PacketType.mpris]
        )
    }

    func testLocalRequestIsAnsweredAndRemoteStateStillUpdatesStore() async {
        let recorder = PacketRecorder()
        let plugin = makePlugin(recorder: recorder)
        let device = makeDevice(id: "phone", incoming: [PacketType.mpris])

        await plugin.handle(packet: .localPlayerListRequest, from: device)

        XCTAssertEqual(
            recorder.packets.last?.body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            ["Mac"]
        )

        await plugin.handle(packet: NetworkPacket(
            type: PacketType.mpris,
            body: ["player": .string("Phone"), "title": .string("Remote Track")]
        ), from: device)

        XCTAssertEqual(MprisStore.shared.state(for: "phone")?.title, "Remote Track")
    }

    func testRemotePlayerFanoutRequestsVolumeExplicitly() async {
        let recorder = PacketRecorder()
        let plugin = makePlugin(recorder: recorder)

        await plugin.handle(packet: NetworkPacket(
            type: PacketType.mpris,
            body: ["playerList": .array([.string("Spotify")])]
        ), from: makeDevice())

        XCTAssertEqual(recorder.packets.last?.body["requestNowPlaying"]?.boolValue, true)
        XCTAssertEqual(recorder.packets.last?.body["requestVolume"]?.boolValue, true)
        XCTAssertEqual(recorder.packets.last?.body["player"]?.stringValue, "Spotify")
    }

    func testRemoteVolumePacketUsesSelectedPlayerAndClampsBothBoundaries() {
        let high = MprisPlugin.volumePacket(player: "Spotify", percent: 140)
        let low = MprisPlugin.volumePacket(player: "Phone Player", percent: -1)

        XCTAssertEqual(high.type, PacketType.mprisRequest)
        XCTAssertEqual(high.body["player"]?.stringValue, "Spotify")
        XCTAssertEqual(high.body["setVolume"]?.intValue, 100)
        XCTAssertEqual(low.body["player"]?.stringValue, "Phone Player")
        XCTAssertEqual(low.body["setVolume"]?.intValue, 0)
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
