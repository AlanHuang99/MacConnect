import Foundation
@testable import MacConnectCore
import XCTest

@MainActor
final class MprisArtworkPayloadSenderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macconnect-artwork-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testSendsNativePayloadPacketUsingTrustedDeviceIdentityAndCleansUpOnSuccess() async throws {
        let transport = FakeArtworkTransport(port: 1743)
        let packets = ArtworkPacketRecorder(sendSucceeds: true)
        let sender = MprisArtworkPayloadSender(
            temporaryDirectory: temporaryDirectory,
            startPayload: transport.start,
            sendPacket: packets.send
        )
        let device = makeDevice(id: "trusted-phone")
        let transfer = fixtureTransfer(data: Data([0xFF, 0xD8, 0xFF, 0xD9]))

        sender.send(transfer, to: device)

        let fileURL = try XCTUnwrap(transport.fileURLs.first)
        XCTAssertEqual(transport.peerDeviceIds, ["trusted-phone"])
        XCTAssertEqual(try Data(contentsOf: fileURL), transfer.data)
        XCTAssertEqual(packets.packets.count, 1)
        XCTAssertEqual(packets.packets[0].type, PacketType.mpris)
        XCTAssertEqual(packets.packets[0].body["player"]?.stringValue, transfer.player)
        XCTAssertEqual(packets.packets[0].body["transferringAlbumArt"]?.boolValue, true)
        XCTAssertEqual(packets.packets[0].body["albumArtUrl"]?.stringValue, transfer.url)
        XCTAssertEqual(packets.packets[0].payloadSize, Int64(transfer.data.count))
        XCTAssertEqual(packets.packets[0].payloadTransferInfo?["port"]?.intValue, 1743)

        transport.finish(at: 0)
        await Task.yield()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testConcurrentTransfersUseUniqueTemporaryFiles() throws {
        let transport = FakeArtworkTransport(port: 1744)
        let sender = MprisArtworkPayloadSender(
            temporaryDirectory: temporaryDirectory,
            startPayload: transport.start,
            sendPacket: ArtworkPacketRecorder(sendSucceeds: true).send
        )
        let device = makeDevice(id: "phone")

        sender.send(fixtureTransfer(data: Data("first".utf8)), to: device)
        sender.send(fixtureTransfer(data: Data("second".utf8)), to: device)

        XCTAssertEqual(Set(transport.fileURLs).count, 2)
        XCTAssertEqual(try Data(contentsOf: transport.fileURLs[0]), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: transport.fileURLs[1]), Data("second".utf8))
    }

    func testEmptyArtworkDoesNotCreateFileOrStartListener() throws {
        let transport = FakeArtworkTransport(port: 1744)
        let packets = ArtworkPacketRecorder(sendSucceeds: true)
        let sender = MprisArtworkPayloadSender(
            temporaryDirectory: temporaryDirectory,
            startPayload: transport.start,
            sendPacket: packets.send
        )

        sender.send(fixtureTransfer(data: Data()), to: makeDevice(id: "phone"))

        XCTAssertTrue(transport.fileURLs.isEmpty)
        XCTAssertTrue(packets.packets.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).isEmpty)
    }

    func testOversizedArtworkDoesNotCreateFileOrStartListener() throws {
        let transport = FakeArtworkTransport(port: 1744)
        let packets = ArtworkPacketRecorder(sendSucceeds: true)
        let sender = MprisArtworkPayloadSender(
            temporaryDirectory: temporaryDirectory,
            startPayload: transport.start,
            sendPacket: packets.send
        )
        let oversized = Data(repeating: 0x41, count: 5 * 1024 * 1024 + 1)

        sender.send(fixtureTransfer(data: oversized), to: makeDevice(id: "phone"))

        XCTAssertTrue(transport.fileURLs.isEmpty)
        XCTAssertTrue(packets.packets.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).isEmpty)
    }

    func testPayloadErrorCleansUpTemporaryFile() async throws {
        let transport = FakeArtworkTransport(port: 1744)
        let sender = MprisArtworkPayloadSender(
            temporaryDirectory: temporaryDirectory,
            startPayload: transport.start,
            sendPacket: ArtworkPacketRecorder(sendSucceeds: true).send
        )

        sender.send(fixtureTransfer(), to: makeDevice(id: "phone"))

        let fileURL = try XCTUnwrap(transport.fileURLs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        transport.fail(at: 0)
        await Task.yield()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testBindFailureCleansUpWithoutSendingControlPacket() {
        let transport = FakeArtworkTransport(port: 0)
        let packets = ArtworkPacketRecorder(sendSucceeds: true)
        let sender = MprisArtworkPayloadSender(
            temporaryDirectory: temporaryDirectory,
            startPayload: transport.start,
            sendPacket: packets.send
        )

        sender.send(fixtureTransfer(), to: makeDevice(id: "phone"))

        XCTAssertTrue(packets.packets.isEmpty)
        XCTAssertEqual(transport.fileURLs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transport.fileURLs[0].path))
    }

    func testFailedControlPacketAbortsListenerAndCleansUp() {
        let transport = FakeArtworkTransport(port: 1745)
        let packets = ArtworkPacketRecorder(sendSucceeds: false)
        let sender = MprisArtworkPayloadSender(
            temporaryDirectory: temporaryDirectory,
            startPayload: transport.start,
            sendPacket: packets.send
        )

        sender.send(fixtureTransfer(), to: makeDevice(id: "phone"))

        XCTAssertEqual(transport.cancelCount, 1)
        XCTAssertEqual(packets.packets.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transport.fileURLs[0].path))
    }

    private func fixtureTransfer(data: Data = Data("cover".utf8)) -> MprisArtworkTransfer {
        MprisArtworkTransfer(
            player: "IINA",
            url: "kdeconnect://macconnect/album-art/current",
            data: data
        )
    }

    private func makeDevice(id: String) -> Device {
        let device = Device(identity: IdentityPayload(
            deviceId: id,
            deviceName: id,
            deviceType: .phone,
            protocolVersion: 7,
            tcpPort: nil,
            incomingCapabilities: [PacketType.mpris],
            outgoingCapabilities: [PacketType.mprisRequest]
        ), paired: true)
        device.isReachable = true
        return device
    }
}

@MainActor
private final class FakeArtworkTransport {
    let port: UInt16
    private(set) var fileURLs: [URL] = []
    private(set) var peerDeviceIds: [String] = []
    private(set) var completions: [@Sendable (MprisArtworkPayloadOutcome) -> Void] = []
    private(set) var cancelCount = 0

    init(port: UInt16) {
        self.port = port
    }

    func start(
        fileURL: URL,
        peerDeviceId: String,
        onFinished: @escaping @Sendable (MprisArtworkPayloadOutcome) -> Void
    ) -> MprisArtworkPayloadListener {
        fileURLs.append(fileURL)
        peerDeviceIds.append(peerDeviceId)
        completions.append(onFinished)
        return MprisArtworkPayloadListener(port: port) { [weak self] in
            self?.cancelCount += 1
        }
    }

    func finish(at index: Int) {
        completions[index](.success)
    }

    func fail(at index: Int) {
        completions[index](.failure)
    }
}

@MainActor
private final class ArtworkPacketRecorder {
    let sendSucceeds: Bool
    private(set) var packets: [NetworkPacket] = []

    init(sendSucceeds: Bool) {
        self.sendSucceeds = sendSucceeds
    }

    func send(_ packet: NetworkPacket, _: Device) -> Bool {
        packets.append(packet)
        return sendSucceeds
    }
}
