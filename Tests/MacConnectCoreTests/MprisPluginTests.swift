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

    func testMatchingArtworkRequestRoutesToSenderWithoutNormalResponse() async {
        let packetRecorder = PacketRecorder()
        let artworkRecorder = ArtworkRecorder()
        var snapshot = populatedSnapshot
        snapshot.playerName = "IINA"
        snapshot.artworkData = Data("cover".utf8)
        let plugin = MprisPlugin(
            localController: FakeLocalMediaController(snapshot: snapshot),
            devices: { [] },
            pluginEnabled: { _ in true },
            sendPacket: packetRecorder.record,
            sendArtwork: artworkRecorder.record
        )
        let device = makeDevice(id: "trusted-phone")
        let url = "kdeconnect://macconnect/album-art/3fa405a8301ace34d11cf44a816080b8f0e49a48fbd048b8aef1543a8c58bdb6"

        await plugin.handle(packet: NetworkPacket(
            type: PacketType.mprisRequest,
            body: ["player": .string("IINA"), "albumArtUrl": .string(url)]
        ), from: device)

        XCTAssertTrue(packetRecorder.packets.isEmpty)
        XCTAssertEqual(artworkRecorder.transfers, [
            MprisArtworkTransfer(player: "IINA", url: url, data: Data("cover".utf8))
        ])
        XCTAssertEqual(artworkRecorder.deviceIds, ["trusted-phone"])
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
            artworkData: nil,
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

    func testChangedCoherentAutomationRefreshFansOutToTwoPhonesWithoutAttach() async {
        let readers = PluginAutomationReaders()
        let bridge = MediaRemoteBridge(
            automationMetadataReader: { await readers.readMetadata() },
            automationArtworkReader: { await readers.readArtwork() },
            pollingInterval: .milliseconds(1)
        )
        let controller = SystemLocalMediaController(
            transport: bridge,
            volumeController: PluginFakeVolumeController(),
            notificationDelay: 0
        )
        let recorder = PacketRecorder()
        let firstBroadcast = expectation(description: "initial state reaches both phones")
        firstBroadcast.expectedFulfillmentCount = 4
        recorder.onRecord = firstBroadcast.fulfill
        let plugin = MprisPlugin(
            localController: controller,
            devices: { [self.makeDevice(id: "k60"), self.makeDevice(id: "note12")] },
            pluginEnabled: { _ in true },
            sendPacket: recorder.record
        )

        let firstReadersStarted = await readers.waitForStarts(metadata: 1, artwork: 1)
        XCTAssertTrue(firstReadersStarted)
        await readers.finishMetadata(pluginMediaState(title: "Red Song"))
        await readers.finishArtwork(Data("red-cover".utf8))
        await fulfillment(of: [firstBroadcast], timeout: 0.5)

        recorder.removeAll()
        let changedBroadcast = expectation(description: "changed state reaches both open controllers")
        changedBroadcast.expectedFulfillmentCount = 2
        recorder.onRecord = changedBroadcast.fulfill
        let secondReadersStarted = await readers.waitForStarts(metadata: 2, artwork: 2)
        XCTAssertTrue(secondReadersStarted)
        await readers.finishArtwork(Data("blue-cover".utf8))
        await readers.finishMetadata(pluginMediaState(title: "Blue Song"))
        await fulfillment(of: [changedBroadcast], timeout: 0.5)

        withExtendedLifetime(plugin) {
            XCTAssertEqual(Set(recorder.deviceIds), ["k60", "note12"])
            XCTAssertEqual(recorder.packets.count, 2)
            XCTAssertTrue(recorder.packets.allSatisfy {
                $0.body["title"]?.stringValue == "Blue Song" &&
                    $0.body["albumArtUrl"]?.stringValue ==
                    "kdeconnect://macconnect/album-art/" +
                    "0bb8e765304cae912187fe15d63f1ba92d0470de442335326f69325163429c34"
            })
        }
        bridge.stopPolling()
    }

    private var populatedSnapshot: LocalMediaSnapshot {
        LocalMediaSnapshot(
            title: "Local Track",
            artist: "Local Artist",
            album: nil,
            artworkData: nil,
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
    var onRecord: (() -> Void)?

    func record(_ packet: NetworkPacket, _ device: Device) {
        packets.append(packet)
        deviceIds.append(device.id)
        onRecord?()
    }

    func removeAll() {
        packets.removeAll()
        deviceIds.removeAll()
    }
}

@MainActor
private final class ArtworkRecorder {
    private(set) var transfers: [MprisArtworkTransfer] = []
    private(set) var deviceIds: [String] = []

    func record(_ transfer: MprisArtworkTransfer, _ device: Device) {
        transfers.append(transfer)
        deviceIds.append(device.id)
    }
}

private extension NetworkPacket {
    static let localPlayerListRequest = NetworkPacket(
        type: PacketType.mprisRequest,
        body: ["requestPlayerList": .bool(true)]
    )
}

private func pluginMediaState(title: String) -> MediaRemoteState {
    MediaRemoteState(
        playerName: "Mac",
        title: title,
        artist: "Artist",
        album: "Album",
        artworkData: nil,
        isPlaying: true,
        isAvailable: true,
        lengthMs: 120_000,
        positionMs: 1000
    )
}

private actor PluginAutomationReaders {
    private var metadataContinuations: [CheckedContinuation<MediaRemoteState?, Never>] = []
    private var artworkContinuations: [CheckedContinuation<Data?, Never>] = []
    private var metadataStarts = 0
    private var artworkStarts = 0

    func readMetadata() async -> MediaRemoteState? {
        metadataStarts += 1
        return await withCheckedContinuation { metadataContinuations.append($0) }
    }

    func readArtwork() async -> Data? {
        artworkStarts += 1
        return await withCheckedContinuation { artworkContinuations.append($0) }
    }

    func finishMetadata(_ state: MediaRemoteState?) {
        metadataContinuations.removeFirst().resume(returning: state)
    }

    func finishArtwork(_ data: Data?) {
        artworkContinuations.removeFirst().resume(returning: data)
    }

    func waitForStarts(metadata: Int, artwork: Int) async -> Bool {
        for _ in 0 ..< 1000 {
            if metadataStarts >= metadata, artworkStarts >= artwork {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

@MainActor
private final class PluginFakeVolumeController: SystemVolumeProviding {
    var volume: Int? = 50
    var isMuted: Bool? = false
    var onChange: (() -> Void)?

    func setVolume(_: Int) {}
    func setMuted(_: Bool) {}
}
