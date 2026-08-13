@testable import MacConnectCore
import XCTest

@MainActor
final class LocalMprisServiceTests: XCTestCase {
    func testPlayerListExposesStableMacPlayerWhenTransportExists() {
        let fake = FakeLocalMediaController(snapshot: .fixture(transportAvailable: true, volume: 42))
        let packets = LocalMprisService(controller: fake).handle(.playerListRequest)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(
            packets[0].body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            ["Mac"]
        )
    }

    func testPlayerListExposesVolumeOnlyMacAndHidesUnavailableMac() {
        let volumeOnly = FakeLocalMediaController(snapshot: .fixture(transportAvailable: false, volume: 21))
        let unavailable = FakeLocalMediaController(snapshot: .fixture(transportAvailable: false, volume: nil))

        XCTAssertEqual(
            LocalMprisService(controller: volumeOnly)
                .handle(.playerListRequest)[0]
                .body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            ["Mac"]
        )
        XCTAssertEqual(
            LocalMprisService(controller: unavailable)
                .handle(.playerListRequest)[0]
                .body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            []
        )
    }

    func testNowPlayingSerializesSnapshotAndUnavailableNavigation() {
        let fake = FakeLocalMediaController(snapshot: .fixture(
            title: "Track",
            artist: "Artist",
            album: "Album",
            isPlaying: true,
            transportAvailable: true,
            volume: 42,
            lengthMs: 180_000,
            positionMs: 12000
        ))

        let response = LocalMprisService(controller: fake).handle(.nowPlayingRequest).first

        XCTAssertEqual(response?.type, PacketType.mpris)
        XCTAssertEqual(response?.body["player"]?.stringValue, "Mac")
        XCTAssertEqual(response?.body["title"]?.stringValue, "Track")
        XCTAssertEqual(response?.body["artist"]?.stringValue, "Artist")
        XCTAssertEqual(response?.body["album"]?.stringValue, "Album")
        XCTAssertEqual(response?.body["isPlaying"]?.boolValue, true)
        XCTAssertEqual(response?.body["canPlay"]?.boolValue, true)
        XCTAssertEqual(response?.body["canPause"]?.boolValue, true)
        XCTAssertEqual(response?.body["canGoNext"]?.boolValue, false)
        XCTAssertEqual(response?.body["canGoPrevious"]?.boolValue, false)
        XCTAssertEqual(response?.body["volume"]?.intValue, 42)
        XCTAssertEqual(response?.body["length"]?.intValue, 180_000)
        XCTAssertEqual(response?.body["pos"]?.intValue, 12000)
    }

    func testUnavailableFieldsAreOmittedAndVolumeUsesProtocolSentinel() {
        let fake = FakeLocalMediaController(snapshot: .fixture(
            transportAvailable: true,
            volume: nil
        ))

        let response = LocalMprisService(controller: fake).handle(.nowPlayingRequest)[0]

        XCTAssertNil(response.body["title"])
        XCTAssertNil(response.body["artist"])
        XCTAssertNil(response.body["album"])
        XCTAssertNil(response.body["length"])
        XCTAssertNil(response.body["pos"])
        XCTAssertEqual(response.body["volume"]?.intValue, -1)
    }

    func testPlayPauseActionsRouteOnlyForMacPlayer() {
        let fake = FakeLocalMediaController(snapshot: .fixture())
        let service = LocalMprisService(controller: fake)

        _ = service.handle(.action("Play"))
        _ = service.handle(.action("Pause"))
        _ = service.handle(.action("PlayPause"))
        _ = service.handle(.action("Next"))
        _ = service.handle(.action("Play", player: "Other"))

        XCTAssertEqual(fake.commands, [.play, .pause, .toggle])
    }

    func testSetVolumeClampsBothProtocolBoundaries() {
        let fake = FakeLocalMediaController(snapshot: .fixture())
        let service = LocalMprisService(controller: fake)

        _ = service.handle(.volume(-7))
        _ = service.handle(.volume(137))

        XCTAssertEqual(fake.volumes, [0, 100])
    }

    func testUnknownPlayerReturnsPlayerListWithoutExecutingCommand() {
        let fake = FakeLocalMediaController(snapshot: .fixture())
        let packets = LocalMprisService(controller: fake).handle(.action("Play", player: "Other"))

        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertEqual(
            packets.first?.body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            ["Mac"]
        )
    }

    func testMalformedVolumeDoesNotExecuteCommand() {
        let fake = FakeLocalMediaController(snapshot: .fixture())
        let packet = NetworkPacket(
            type: PacketType.mprisRequest,
            body: ["player": .string("Mac"), "setVolume": .string("loud")]
        )

        _ = LocalMprisService(controller: fake).handle(packet)

        XCTAssertTrue(fake.volumes.isEmpty)
    }

    func testOutOfRangeNumericVolumeDoesNotExecuteCommand() {
        let fake = FakeLocalMediaController(snapshot: .fixture())
        let packet = NetworkPacket(
            type: PacketType.mprisRequest,
            body: ["player": .string("Mac"), "setVolume": .double(1e300)]
        )

        _ = LocalMprisService(controller: fake).handle(packet)

        XCTAssertTrue(fake.volumes.isEmpty)
    }
}

@MainActor
final class FakeLocalMediaController: LocalMediaControlling {
    enum Command: Equatable {
        case play
        case pause
        case toggle
    }

    var snapshot: LocalMediaSnapshot
    var onStateChange: (() -> Void)?
    private(set) var commands: [Command] = []
    private(set) var volumes: [Int] = []

    init(snapshot: LocalMediaSnapshot) {
        self.snapshot = snapshot
    }

    func play() {
        commands.append(.play)
    }

    func pause() {
        commands.append(.pause)
    }

    func togglePlayPause() {
        commands.append(.toggle)
    }

    func setVolume(_ percent: Int) {
        volumes.append(percent)
    }

    func emitChange() {
        onStateChange?()
    }
}

private extension LocalMediaSnapshot {
    static func fixture(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        isPlaying: Bool = false,
        transportAvailable: Bool = true,
        volume: Int? = 50,
        lengthMs: Int64? = nil,
        positionMs: Int64? = nil
    ) -> LocalMediaSnapshot {
        LocalMediaSnapshot(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            transportAvailable: transportAvailable,
            volume: volume,
            lengthMs: lengthMs,
            positionMs: positionMs
        )
    }
}

private extension NetworkPacket {
    static let playerListRequest = NetworkPacket(
        type: PacketType.mprisRequest,
        body: ["requestPlayerList": .bool(true)]
    )

    static let nowPlayingRequest = NetworkPacket(
        type: PacketType.mprisRequest,
        body: [
            "player": .string("Mac"),
            "requestNowPlaying": .bool(true),
            "requestVolume": .bool(true)
        ]
    )

    static func action(_ action: String, player: String = "Mac") -> NetworkPacket {
        NetworkPacket(
            type: PacketType.mprisRequest,
            body: ["player": .string(player), "action": .string(action)]
        )
    }

    static func volume(_ percent: Int) -> NetworkPacket {
        NetworkPacket(
            type: PacketType.mprisRequest,
            body: ["player": .string("Mac"), "setVolume": .int(Int64(percent))]
        )
    }
}
