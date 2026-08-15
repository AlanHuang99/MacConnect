@testable import MacConnectCore
import XCTest

final class SystemMediaBridgeTests: XCTestCase {
    func testReadStrategyUsesAutomationHostWhenLegacyCallbacksAreRestricted() {
        XCTAssertEqual(
            MediaRemoteReadStrategy.forVersion(OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 4,
                patchVersion: 0
            )),
            .automationHost
        )
        XCTAssertEqual(
            MediaRemoteReadStrategy.forVersion(OperatingSystemVersion(
                majorVersion: 26,
                minorVersion: 0,
                patchVersion: 0
            )),
            .automationHost
        )
        XCTAssertEqual(
            MediaRemoteReadStrategy.forVersion(OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 3,
                patchVersion: 2
            )),
            .legacyCallbacks
        )
    }

    func testAutomationSnapshotDecoderMapsLiveNowPlayingState() throws {
        let data = Data(#"{"available":true,"playerName":"IINA","title":"Song","artist":"Singer","album":"Album","duration":201.5,"elapsed":9.25,"rate":1}"#
            .utf8)

        let state = try MediaRemoteAutomationSnapshot.decode(data)

        XCTAssertEqual(state, MediaRemoteState(
            playerName: "IINA",
            title: "Song",
            artist: "Singer",
            album: "Album",
            artworkData: nil,
            isPlaying: true,
            isAvailable: true,
            lengthMs: 201_500,
            positionMs: 9250
        ))
    }

    func testAutomationSnapshotDecoderMapsNoActivePlayer() throws {
        let state = try MediaRemoteAutomationSnapshot.decode(Data(#"{"available":false}"#.utf8))

        XCTAssertEqual(state, .unavailable)
    }

    func testRefreshGenerationRejectsOlderCompletion() {
        var generation = MediaRemoteRefreshGeneration()

        let first = generation.begin()
        let second = generation.begin()

        XCTAssertFalse(generation.isCurrent(first))
        XCTAssertTrue(generation.isCurrent(second))
    }

    func testVolumeAddressStrategyFallsBackWhenMainVolumeIsUnreadable() {
        XCTAssertEqual(
            SystemVolumeAddressStrategy.preferredElements(
                mainIsReadable: false,
                usableChannelElements: [1, 2]
            ),
            [1, 2]
        )
    }

    func testVolumeAddressStrategyKeepsChannelsAsRuntimeFallback() {
        let strategy = SystemVolumeAddressStrategy.resolve(
            mainIsReadable: true,
            usableChannelElements: [1, 2]
        )

        XCTAssertEqual(strategy.primaryElements, [0])
        XCTAssertEqual(strategy.fallbackElements, [1, 2])
    }

    func testVolumeMathClampsAndRoundsProtocolPercent() {
        XCTAssertEqual(SystemVolumeMath.percent(fromScalar: 0.425), 43)
        XCTAssertEqual(SystemVolumeMath.scalar(fromPercent: -3), 0.0)
        XCTAssertEqual(SystemVolumeMath.scalar(fromPercent: 135), 1.0)
    }

    func testVolumeMathAveragesChannelFallback() {
        XCTAssertEqual(SystemVolumeMath.average([0.2, 0.6]) ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertNil(SystemVolumeMath.average([]))
    }

    @MainActor
    func testSystemControllerCombinesStateAndForwardsCommands() {
        let transport = FakeMediaRemoteController(state: MediaRemoteState(
            playerName: "IINA",
            title: "Song",
            artist: "Singer",
            album: "Album",
            artworkData: Data("cover".utf8),
            isPlaying: true,
            isAvailable: true,
            lengthMs: 200_000,
            positionMs: 15000
        ))
        let volume = FakeSystemVolumeController(volume: 64)
        let controller = SystemLocalMediaController(
            transport: transport,
            volumeController: volume
        )

        XCTAssertEqual(controller.snapshot, LocalMediaSnapshot(
            playerName: "IINA",
            title: "Song",
            artist: "Singer",
            album: "Album",
            artworkData: Data("cover".utf8),
            isPlaying: true,
            transportAvailable: true,
            volume: 64,
            lengthMs: 200_000,
            positionMs: 15000
        ))

        controller.play()
        controller.pause()
        controller.togglePlayPause()
        controller.previous()
        controller.next()
        controller.setVolume(73)

        XCTAssertEqual(transport.commands, [.play, .pause, .toggle, .previous, .next])
        XCTAssertEqual(volume.requestedVolumes, [73])
    }

    @MainActor
    func testSystemControllerCoalescesDependencyChanges() async {
        let transport = FakeMediaRemoteController(state: .unavailable)
        let volume = FakeSystemVolumeController(volume: 50)
        let controller = SystemLocalMediaController(
            transport: transport,
            volumeController: volume,
            notificationDelay: 0.01
        )
        let changed = expectation(description: "one coalesced change")
        changed.expectedFulfillmentCount = 1
        changed.assertForOverFulfill = true
        controller.onStateChange = { changed.fulfill() }

        transport.emitChange()
        volume.emitChange()

        await fulfillment(of: [changed], timeout: 0.2)
    }

    func testMetadataMapperConvertsSecondsToMilliseconds() {
        let keys = MediaRemoteMetadataKeys(
            title: "title",
            artist: "artist",
            album: "album",
            duration: "duration",
            elapsedTime: "elapsed"
        )

        let state = MediaRemoteMetadataMapper.map(
            [
                "title": "Song",
                "artist": "Singer",
                "album": "Record",
                "duration": 201.5,
                "elapsed": 9.25
            ],
            isPlaying: true,
            keys: keys
        )

        XCTAssertEqual(state.title, "Song")
        XCTAssertEqual(state.artist, "Singer")
        XCTAssertEqual(state.album, "Record")
        XCTAssertEqual(state.lengthMs, 201_500)
        XCTAssertEqual(state.positionMs, 9250)
        XCTAssertTrue(state.isPlaying)
        XCTAssertTrue(state.isAvailable)
    }

    func testMetadataMapperDropsInvalidAndNegativeTiming() {
        let keys = MediaRemoteMetadataKeys(
            title: "title",
            artist: "artist",
            album: "album",
            duration: "duration",
            elapsedTime: "elapsed"
        )

        let state = MediaRemoteMetadataMapper.map(
            ["duration": -1.0, "elapsed": "not-a-number"],
            isPlaying: false,
            keys: keys
        )

        XCTAssertNil(state.lengthMs)
        XCTAssertNil(state.positionMs)
        XCTAssertFalse(state.isPlaying)
    }

    func testMetadataMapperOmitsEmptyText() {
        let keys = MediaRemoteMetadataKeys(
            title: "title",
            artist: "artist",
            album: "album",
            duration: "duration",
            elapsedTime: "elapsed"
        )

        let state = MediaRemoteMetadataMapper.map(
            ["title": "", "artist": "  ", "album": "Album"],
            isPlaying: false,
            keys: keys
        )

        XCTAssertNil(state.title)
        XCTAssertNil(state.artist)
        XCTAssertEqual(state.album, "Album")
    }
}

@MainActor
private final class FakeMediaRemoteController: MediaRemoteControlling {
    enum Command: Equatable {
        case play
        case pause
        case toggle
        case previous
        case next
    }

    var state: MediaRemoteState
    var onChange: (() -> Void)?
    private(set) var commands: [Command] = []

    init(state: MediaRemoteState) {
        self.state = state
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

    func emitChange() {
        onChange?()
    }
}

@MainActor
private final class FakeSystemVolumeController: SystemVolumeProviding {
    var volume: Int?
    var isMuted: Bool? = false
    var onChange: (() -> Void)?
    private(set) var requestedVolumes: [Int] = []

    init(volume: Int?) {
        self.volume = volume
    }

    func setVolume(_ percent: Int) {
        requestedVolumes.append(percent)
    }

    func setMuted(_: Bool) {}

    func emitChange() {
        onChange?()
    }
}
