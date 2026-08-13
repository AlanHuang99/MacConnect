@testable import MacConnectCore
import XCTest

final class SystemMediaBridgeTests: XCTestCase {
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
            title: "Song",
            artist: "Singer",
            album: "Album",
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
            title: "Song",
            artist: "Singer",
            album: "Album",
            isPlaying: true,
            transportAvailable: true,
            volume: 64,
            lengthMs: 200_000,
            positionMs: 15000
        ))

        controller.play()
        controller.pause()
        controller.togglePlayPause()
        controller.setVolume(73)

        XCTAssertEqual(transport.commands, [.play, .pause, .toggle])
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

    func emitChange() {
        onChange?()
    }
}

@MainActor
private final class FakeSystemVolumeController: SystemVolumeProviding {
    var volume: Int?
    var onChange: (() -> Void)?
    private(set) var requestedVolumes: [Int] = []

    init(volume: Int?) {
        self.volume = volume
    }

    func setVolume(_ percent: Int) {
        requestedVolumes.append(percent)
    }

    func emitChange() {
        onChange?()
    }
}
