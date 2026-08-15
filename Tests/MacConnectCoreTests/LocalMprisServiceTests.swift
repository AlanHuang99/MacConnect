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
        XCTAssertEqual(packets[0].body["supportAlbumArtPayload"]?.boolValue, true)
    }

    func testCurrentStateUsesStableContentAddressedArtworkURL() {
        let fake = FakeLocalMediaController(snapshot: .fixture(
            title: "First title",
            artworkData: Data("cover".utf8)
        ))
        let service = LocalMprisService(controller: fake)
        let expected = "kdeconnect://macconnect/album-art/3fa405a8301ace34d11cf44a816080b8f0e49a48fbd048b8aef1543a8c58bdb6"

        XCTAssertEqual(service.currentStatePacket()?.body["albumArtUrl"]?.stringValue, expected)

        fake.snapshot.title = "Metadata refresh"
        XCTAssertEqual(service.currentStatePacket()?.body["albumArtUrl"]?.stringValue, expected)
    }

    func testArtworkAtLimitIsAdvertisedButEmptyAndOversizedArtworkAreOmitted() {
        let fake = FakeLocalMediaController(snapshot: .fixture(artworkData: Data(
            repeating: 0x41,
            count: 5 * 1024 * 1024
        )))
        let service = LocalMprisService(controller: fake)

        XCTAssertEqual(service.currentStatePacket()?.body["albumArtUrl"]?.stringValue?.hasPrefix("kdeconnect://"), true)

        fake.snapshot.artworkData = Data()
        XCTAssertNil(service.currentStatePacket()?.body["albumArtUrl"])

        fake.snapshot.artworkData = Data(repeating: 0x41, count: 5 * 1024 * 1024 + 1)
        XCTAssertNil(service.currentStatePacket()?.body["albumArtUrl"])
    }

    func testArtworkTransferRequiresExactCurrentPlayerAndURLRequest() {
        let artwork = Data("cover".utf8)
        let fake = FakeLocalMediaController(snapshot: .fixture(
            playerName: "IINA",
            artworkData: artwork
        ))
        let service = LocalMprisService(controller: fake)
        let currentURL = "kdeconnect://macconnect/album-art/3fa405a8301ace34d11cf44a816080b8f0e49a48fbd048b8aef1543a8c58bdb6"

        XCTAssertEqual(
            service.artworkTransfer(for: .artworkRequest(player: "IINA", url: currentURL)),
            MprisArtworkTransfer(player: "IINA", url: currentURL, data: artwork)
        )
        XCTAssertNil(service.artworkTransfer(for: .artworkRequest(player: "IINA", url: currentURL + "-stale")))
        XCTAssertNil(service.artworkTransfer(for: .artworkRequest(player: "Mac", url: currentURL)))
        XCTAssertNil(service.artworkTransfer(for: .nowPlayingRequest))
        XCTAssertNil(service.artworkTransfer(for: NetworkPacket(
            type: PacketType.mpris,
            body: ["player": .string("IINA"), "albumArtUrl": .string(currentURL)]
        )))
    }

    func testPlayerListDoesNotExposeVolumeAsAFakeMediaPlayer() {
        let volumeOnly = FakeLocalMediaController(snapshot: .fixture(transportAvailable: false, volume: 21))
        let unavailable = FakeLocalMediaController(snapshot: .fixture(transportAvailable: false, volume: nil))

        XCTAssertEqual(
            LocalMprisService(controller: volumeOnly)
                .handle(.playerListRequest)[0]
                .body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            []
        )
        XCTAssertEqual(
            LocalMprisService(controller: unavailable)
                .handle(.playerListRequest)[0]
                .body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            []
        )
    }

    func testPlayerListAndStateUseCurrentApplicationName() {
        let fake = FakeLocalMediaController(snapshot: .fixture(
            playerName: "IINA",
            title: "Numb",
            artist: "LINKIN PARK"
        ))
        let service = LocalMprisService(controller: fake)

        XCTAssertEqual(
            service.playerListPacket().body["playerList"]?.arrayValue?.compactMap(\.stringValue),
            ["IINA"]
        )
        XCTAssertEqual(service.currentStatePacket()?.body["player"]?.stringValue, "IINA")
    }

    func testNowPlayingSerializesSnapshotAndAvailableNavigation() {
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
        XCTAssertEqual(response?.body["canGoNext"]?.boolValue, true)
        XCTAssertEqual(response?.body["canGoPrevious"]?.boolValue, true)
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

    func testTransportActionsRouteOnlyForMacPlayer() {
        let fake = FakeLocalMediaController(snapshot: .fixture())
        let service = LocalMprisService(controller: fake)

        _ = service.handle(.action("Play"))
        _ = service.handle(.action("Pause"))
        _ = service.handle(.action("PlayPause"))
        _ = service.handle(.action("Previous"))
        _ = service.handle(.action("Next"))
        _ = service.handle(.action("Play", player: "Other"))

        XCTAssertEqual(fake.commands, [.play, .pause, .toggle, .previous, .next])
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
        case previous
        case next
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

    func previous() {
        commands.append(.previous)
    }

    func next() {
        commands.append(.next)
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
        playerName: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        artworkData: Data? = nil,
        isPlaying: Bool = false,
        transportAvailable: Bool = true,
        volume: Int? = 50,
        lengthMs: Int64? = nil,
        positionMs: Int64? = nil
    ) -> LocalMediaSnapshot {
        LocalMediaSnapshot(
            playerName: playerName,
            title: title,
            artist: artist,
            album: album,
            artworkData: artworkData,
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

    static func artworkRequest(player: String, url: String) -> NetworkPacket {
        NetworkPacket(
            type: PacketType.mprisRequest,
            body: ["player": .string(player), "albumArtUrl": .string(url)]
        )
    }
}
