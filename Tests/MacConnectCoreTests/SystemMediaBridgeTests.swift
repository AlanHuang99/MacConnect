@testable import MacConnectCore
import XCTest

final class SystemMediaBridgeTests: XCTestCase {
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
        XCTAssertEqual(state.positionMs, 9_250)
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
