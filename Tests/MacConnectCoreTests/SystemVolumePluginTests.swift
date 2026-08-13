@testable import MacConnectCore
import XCTest

@MainActor
final class SystemVolumePluginTests: XCTestCase {
    func testCapabilitiesMatchKDESystemVolumeProtocol() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.incomingCapabilities, [PacketType.systemVolumeRequest])
        XCTAssertEqual(plugin.outgoingCapabilities, [PacketType.systemVolume])
    }

    func testAttachSendsCurrentOutputAsSingleSink() async throws {
        let recorder = SystemVolumePacketRecorder()
        let plugin = makePlugin(volume: 42, muted: true, recorder: recorder)

        await plugin.attach(to: makeDevice())

        let packet = try XCTUnwrap(recorder.packets.last)
        XCTAssertEqual(packet.type, PacketType.systemVolume)
        let sink = try XCTUnwrap(packet.body["sinkList"]?.arrayValue?.first?.dictValue)
        XCTAssertEqual(sink["name"]?.stringValue, "default-output")
        XCTAssertEqual(sink["description"]?.stringValue, "Mac Output")
        XCTAssertEqual(sink["volume"]?.intValue, 42)
        XCTAssertEqual(sink["maxVolume"]?.intValue, 100)
        XCTAssertEqual(sink["muted"]?.boolValue, true)
        XCTAssertEqual(sink["enabled"]?.boolValue, true)
    }

    func testRequestSinksReturnsCurrentSinkList() async throws {
        let recorder = SystemVolumePacketRecorder()
        let plugin = makePlugin(volume: 27, muted: false, recorder: recorder)

        await plugin.handle(packet: NetworkPacket(
            type: PacketType.systemVolumeRequest,
            body: ["requestSinks": .bool(true)]
        ), from: makeDevice())

        let sink = try XCTUnwrap(recorder.packets.last?.body["sinkList"]?.arrayValue?.first?.dictValue)
        XCTAssertEqual(sink["volume"]?.intValue, 27)
        XCTAssertEqual(sink["muted"]?.boolValue, false)
    }

    func testVolumeAndMuteRequestsControlCurrentOutput() async {
        let volume = FakeSystemVolumeProvider(volume: 50, muted: false)
        let plugin = makePlugin(provider: volume)
        let device = makeDevice()

        await plugin.handle(packet: NetworkPacket(
            type: PacketType.systemVolumeRequest,
            body: ["name": .string("default-output"), "volume": .int(140)]
        ), from: device)
        await plugin.handle(packet: NetworkPacket(
            type: PacketType.systemVolumeRequest,
            body: ["name": .string("default-output"), "muted": .bool(true)]
        ), from: device)

        XCTAssertEqual(volume.requestedVolumes, [100])
        XCTAssertEqual(volume.requestedMutes, [true])
    }

    func testUnknownSinkRequestsAreIgnored() async {
        let volume = FakeSystemVolumeProvider(volume: 50, muted: false)
        let plugin = makePlugin(provider: volume)

        await plugin.handle(packet: NetworkPacket(
            type: PacketType.systemVolumeRequest,
            body: [
                "name": .string("not-our-output"),
                "volume": .int(12),
                "muted": .bool(true)
            ]
        ), from: makeDevice())

        XCTAssertTrue(volume.requestedVolumes.isEmpty)
        XCTAssertTrue(volume.requestedMutes.isEmpty)
    }

    func testLocalChangeBroadcastsOnlyToEligibleDevices() {
        let eligible = makeDevice(id: "eligible")
        let offline = makeDevice(id: "offline", reachable: false)
        let incompatible = makeDevice(id: "incompatible", incoming: [])
        let disabled = makeDevice(id: "disabled")
        let recorder = SystemVolumePacketRecorder()
        let volume = FakeSystemVolumeProvider(volume: 61, muted: false)
        let plugin = SystemVolumePlugin(
            volumeProvider: volume,
            devices: { [eligible, offline, incompatible, disabled] },
            pluginEnabled: { $0 != "disabled" },
            sendPacket: recorder.record
        )

        withExtendedLifetime(plugin) { volume.emitChange() }

        XCTAssertEqual(recorder.deviceIds, ["eligible"])
        XCTAssertEqual(recorder.packets.first?.body["volume"]?.intValue, 61)
        XCTAssertEqual(recorder.packets.first?.body["muted"]?.boolValue, false)
        XCTAssertEqual(recorder.packets.first?.body["name"]?.stringValue, "default-output")
    }

    private func makePlugin(
        volume: Int = 50,
        muted: Bool = false,
        recorder: SystemVolumePacketRecorder? = nil
    ) -> SystemVolumePlugin {
        makePlugin(
            provider: FakeSystemVolumeProvider(volume: volume, muted: muted),
            recorder: recorder
        )
    }

    private func makePlugin(
        provider: FakeSystemVolumeProvider,
        recorder: SystemVolumePacketRecorder? = nil
    ) -> SystemVolumePlugin {
        let recorder = recorder ?? SystemVolumePacketRecorder()
        return SystemVolumePlugin(
            volumeProvider: provider,
            devices: { [] },
            pluginEnabled: { _ in true },
            sendPacket: recorder.record
        )
    }

    private func makeDevice(
        id: String = "phone",
        reachable: Bool = true,
        incoming: [String] = [PacketType.systemVolume]
    ) -> Device {
        let device = Device(identity: IdentityPayload(
            deviceId: id,
            deviceName: id,
            deviceType: .phone,
            protocolVersion: 7,
            tcpPort: nil,
            incomingCapabilities: incoming,
            outgoingCapabilities: [PacketType.systemVolumeRequest]
        ), paired: true)
        device.isReachable = reachable
        return device
    }
}

@MainActor
private final class FakeSystemVolumeProvider: SystemVolumeProviding {
    var volume: Int?
    var isMuted: Bool?
    var onChange: (() -> Void)?
    private(set) var requestedVolumes: [Int] = []
    private(set) var requestedMutes: [Bool] = []

    init(volume: Int?, muted: Bool?) {
        self.volume = volume
        isMuted = muted
    }

    func setVolume(_ percent: Int) {
        requestedVolumes.append(percent)
    }

    func setMuted(_ muted: Bool) {
        requestedMutes.append(muted)
    }

    func emitChange() {
        onChange?()
    }
}

@MainActor
private final class SystemVolumePacketRecorder {
    private(set) var packets: [NetworkPacket] = []
    private(set) var deviceIds: [String] = []

    func record(_ packet: NetworkPacket, _ device: Device) {
        packets.append(packet)
        deviceIds.append(device.id)
    }
}
