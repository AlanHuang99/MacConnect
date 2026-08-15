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

    func testRefreshOrchestratorStagesArtworkUntilMatchingMetadataArrives() throws {
        var orchestrator = MediaRemoteRefreshOrchestrator()
        let generation = orchestrator.begin()
        let oldState = MediaRemoteState(
            playerName: "Old Player",
            title: "Old Song",
            artist: nil,
            album: nil,
            artworkData: Data("old-cover".utf8),
            isPlaying: false,
            isAvailable: true,
            lengthMs: nil,
            positionMs: nil
        )
        let newArtwork = Data("new-cover".utf8)

        XCTAssertNil(orchestrator.receiveArtwork(
            newArtwork,
            currentState: oldState,
            generation: generation
        ))

        let merged = try XCTUnwrap(orchestrator.receiveMetadata(MediaRemoteState(
            playerName: "New Player",
            title: "New Song",
            artist: "Artist",
            album: "Album",
            artworkData: nil,
            isPlaying: true,
            isAvailable: true,
            lengthMs: 200_000,
            positionMs: 12000
        ), generation: generation))

        XCTAssertEqual(merged.title, "New Song")
        XCTAssertEqual(merged.artworkData, newArtwork)
    }

    func testRefreshOrchestratorAppliesArtworkAfterMetadataArrives() throws {
        var orchestrator = MediaRemoteRefreshOrchestrator()
        let generation = orchestrator.begin()
        let metadata = try XCTUnwrap(orchestrator.receiveMetadata(MediaRemoteState(
            playerName: "IINA",
            title: "Song",
            artist: "Artist",
            album: nil,
            artworkData: nil,
            isPlaying: true,
            isAvailable: true,
            lengthMs: nil,
            positionMs: nil
        ), generation: generation))

        XCTAssertNil(metadata.artworkData)

        let merged = try XCTUnwrap(orchestrator.receiveArtwork(
            Data("cover".utf8),
            currentState: metadata,
            generation: generation
        ))

        XCTAssertEqual(merged.title, "Song")
        XCTAssertEqual(merged.artworkData, Data("cover".utf8))
    }

    func testRefreshOrchestratorRejectsStaleMetadataAndArtwork() {
        var orchestrator = MediaRemoteRefreshOrchestrator()
        let staleGeneration = orchestrator.begin()
        let currentGeneration = orchestrator.begin()
        let state = MediaRemoteState(
            playerName: "IINA",
            title: "Current Song",
            artist: nil,
            album: nil,
            artworkData: nil,
            isPlaying: false,
            isAvailable: true,
            lengthMs: nil,
            positionMs: nil
        )

        XCTAssertNil(orchestrator.receiveMetadata(state, generation: staleGeneration))
        XCTAssertNil(orchestrator.receiveArtwork(
            Data("stale-cover".utf8),
            currentState: state,
            generation: staleGeneration
        ))
        XCTAssertNotNil(orchestrator.receiveMetadata(state, generation: currentGeneration))
    }

    func testNilArtworkBeforeMetadataPreservesMediaAvailability() throws {
        var orchestrator = MediaRemoteRefreshOrchestrator()
        let generation = orchestrator.begin()
        let oldState = MediaRemoteState.unavailable

        XCTAssertNil(orchestrator.receiveArtwork(
            nil,
            currentState: oldState,
            generation: generation
        ))

        let merged = try XCTUnwrap(orchestrator.receiveMetadata(MediaRemoteState(
            playerName: "Music",
            title: "Available Song",
            artist: nil,
            album: nil,
            artworkData: nil,
            isPlaying: false,
            isAvailable: true,
            lengthMs: nil,
            positionMs: nil
        ), generation: generation))

        XCTAssertTrue(merged.isAvailable)
        XCTAssertEqual(merged.title, "Available Song")
        XCTAssertNil(merged.artworkData)
    }

    @MainActor
    func testAutomationRefreshAppliesArtworkAndMetadataOnceWhenArtworkFinishesFirst() async {
        let readers = ControlledAutomationReaders()
        let changed = expectation(description: "one coherent state change")
        changed.assertForOverFulfill = true
        let bridge = MediaRemoteBridge(
            automationMetadataReader: { await readers.readMetadata() },
            automationArtworkReader: { await readers.readArtwork() },
            pollingInterval: .seconds(60)
        )
        bridge.onChange = changed.fulfill

        let readersStarted = await readers.waitForStarts(metadata: 1, artwork: 1)
        XCTAssertTrue(readersStarted)
        await readers.finishArtwork(Data("cover".utf8))
        await Task.yield()
        XCTAssertEqual(bridge.state, .unavailable)

        await readers.finishMetadata(mediaState(title: "Song"))
        await fulfillment(of: [changed], timeout: 0.5)

        XCTAssertEqual(bridge.state.title, "Song")
        XCTAssertEqual(bridge.state.artworkData, Data("cover".utf8))
        bridge.stopPolling()
    }

    @MainActor
    func testAutomationRefreshAppliesArtworkAndMetadataOnceWhenMetadataFinishesFirst() async {
        let readers = ControlledAutomationReaders()
        let changed = expectation(description: "one coherent state change")
        changed.assertForOverFulfill = true
        let bridge = MediaRemoteBridge(
            automationMetadataReader: { await readers.readMetadata() },
            automationArtworkReader: { await readers.readArtwork() },
            pollingInterval: .seconds(60)
        )
        bridge.onChange = changed.fulfill

        let readersStarted = await readers.waitForStarts(metadata: 1, artwork: 1)
        XCTAssertTrue(readersStarted)
        await readers.finishMetadata(mediaState(title: "Song"))
        await Task.yield()
        XCTAssertEqual(bridge.state, .unavailable)

        await readers.finishArtwork(Data("cover".utf8))
        await fulfillment(of: [changed], timeout: 0.5)

        XCTAssertEqual(bridge.state.title, "Song")
        XCTAssertEqual(bridge.state.artworkData, Data("cover".utf8))
        bridge.stopPolling()
    }

    @MainActor
    func testSlowAutomationMetadataIsNotInvalidatedAndKeepsFastArtwork() async throws {
        let readers = ControlledAutomationReaders()
        let changed = expectation(description: "slow refresh still applies")
        let bridge = MediaRemoteBridge(
            automationMetadataReader: { await readers.readMetadata() },
            automationArtworkReader: { await readers.readArtwork() },
            pollingInterval: .seconds(1)
        )
        bridge.onChange = changed.fulfill

        let readersStarted = await readers.waitForStarts(metadata: 1, artwork: 1)
        XCTAssertTrue(readersStarted)
        await readers.finishArtwork(Data("slow-cover".utf8))
        try await Task.sleep(for: .milliseconds(1100))
        let starts = await readers.startCounts
        XCTAssertEqual(starts.metadata, 1)
        XCTAssertEqual(starts.artwork, 1)
        XCTAssertEqual(bridge.state, .unavailable)

        await readers.finishMetadata(mediaState(title: "Slow Song"))
        await fulfillment(of: [changed], timeout: 0.5)

        XCTAssertEqual(bridge.state.title, "Slow Song")
        XCTAssertEqual(bridge.state.artworkData, Data("slow-cover".utf8))
        bridge.stopPolling()
    }

    @MainActor
    func testAutomationArtworkTimeoutEmitsMetadataWithoutArtwork() async {
        let metadataReader = ControlledAutomationReaders()
        let artworkReader = CancellationSafeStalledArtworkReader()
        let changed = expectation(description: "metadata emitted after artwork timeout")
        changed.assertForOverFulfill = true
        let bridge = MediaRemoteBridge(
            automationMetadataReader: { await metadataReader.readMetadata() },
            automationArtworkReader: { await artworkReader.read() },
            pollingInterval: .seconds(60)
        )
        bridge.onChange = changed.fulfill

        let metadataStarted = await metadataReader.waitForMetadataStarts(1)
        let artworkStarted = await artworkReader.waitForReads(1)
        XCTAssertTrue(metadataStarted)
        XCTAssertTrue(artworkStarted)
        await metadataReader.finishMetadata(mediaState(title: "Metadata Only"))
        await fulfillment(of: [changed], timeout: 0.5)

        XCTAssertEqual(bridge.state.title, "Metadata Only")
        XCTAssertNil(bridge.state.artworkData)
        bridge.stopPolling()
    }

    @MainActor
    func testAutomationArtworkTimeoutContinuesPollingAndRejectsLateArtwork() async {
        let metadataReader = ControlledAutomationReaders()
        let artworkReader = CancellationSafeStalledArtworkReader(
            cancelledArtwork: Data("late-cover".utf8),
            nextArtwork: Data("current-cover".utf8)
        )
        let firstChanged = expectation(description: "timed out refresh")
        let secondChanged = expectation(description: "next refresh")
        var states: [MediaRemoteState] = []
        let bridge = MediaRemoteBridge(
            automationMetadataReader: { await metadataReader.readMetadata() },
            automationArtworkReader: { await artworkReader.read() },
            pollingInterval: .milliseconds(1),
            artworkTimeout: .milliseconds(10)
        )
        bridge.onChange = {
            states.append(bridge.state)
            if states.count == 1 {
                firstChanged.fulfill()
            } else if states.count == 2 {
                secondChanged.fulfill()
            }
        }

        let firstMetadataStarted = await metadataReader.waitForMetadataStarts(1)
        let firstArtworkStarted = await artworkReader.waitForReads(1)
        XCTAssertTrue(firstMetadataStarted)
        XCTAssertTrue(firstArtworkStarted)
        await metadataReader.finishMetadata(mediaState(title: "First Song"))
        await fulfillment(of: [firstChanged], timeout: 0.5)

        XCTAssertEqual(states.first?.title, "First Song")
        XCTAssertNil(states.first?.artworkData)

        let secondMetadataStarted = await metadataReader.waitForMetadataStarts(2)
        let secondArtworkStarted = await artworkReader.waitForReads(2)
        XCTAssertTrue(secondMetadataStarted)
        XCTAssertTrue(secondArtworkStarted)
        await metadataReader.finishMetadata(mediaState(title: "Second Song"))
        await fulfillment(of: [secondChanged], timeout: 0.5)

        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states.last?.title, "Second Song")
        XCTAssertEqual(states.last?.artworkData, Data("current-cover".utf8))
        XCTAssertFalse(states.contains { $0.artworkData == Data("late-cover".utf8) })
        bridge.stopPolling()
    }

    @MainActor
    func testNilAutomationArtworkEmitsMetadataAndClearsOldCover() async {
        let readers = ControlledAutomationReaders()
        let changed = expectation(description: "old and new coherent states")
        changed.expectedFulfillmentCount = 2
        let bridge = MediaRemoteBridge(
            automationMetadataReader: { await readers.readMetadata() },
            automationArtworkReader: { await readers.readArtwork() },
            pollingInterval: .milliseconds(1)
        )
        bridge.onChange = changed.fulfill

        let firstReadersStarted = await readers.waitForStarts(metadata: 1, artwork: 1)
        XCTAssertTrue(firstReadersStarted)
        await readers.finishMetadata(mediaState(title: "Old Song"))
        await readers.finishArtwork(Data("old-cover".utf8))
        let secondReadersStarted = await readers.waitForStarts(metadata: 2, artwork: 2)
        XCTAssertTrue(secondReadersStarted)
        await readers.finishArtwork(nil)
        await readers.finishMetadata(mediaState(title: "New Song"))
        await fulfillment(of: [changed], timeout: 0.5)

        XCTAssertEqual(bridge.state.title, "New Song")
        XCTAssertNil(bridge.state.artworkData)
        bridge.stopPolling()
    }

    @MainActor
    func testCancellingAutomationPollingRejectsLateReaderCompletions() async throws {
        let readers = ControlledAutomationReaders()
        var changeCount = 0
        let bridge = MediaRemoteBridge(
            automationMetadataReader: { await readers.readMetadata() },
            automationArtworkReader: { await readers.readArtwork() },
            pollingInterval: .seconds(60)
        )
        bridge.onChange = { changeCount += 1 }

        let readersStarted = await readers.waitForStarts(metadata: 1, artwork: 1)
        XCTAssertTrue(readersStarted)
        bridge.stopPolling()
        await readers.finishMetadata(mediaState(title: "Late Song"))
        await readers.finishArtwork(Data("late-cover".utf8))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(bridge.state, .unavailable)
        XCTAssertEqual(changeCount, 0)
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

private func mediaState(title: String, playerName: String = "Mac") -> MediaRemoteState {
    MediaRemoteState(
        playerName: playerName,
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

private actor ControlledAutomationReaders {
    private var metadataContinuations: [CheckedContinuation<MediaRemoteState?, Never>] = []
    private var artworkContinuations: [CheckedContinuation<Data?, Never>] = []
    private(set) var metadataStarts = 0
    private(set) var artworkStarts = 0

    var startCounts: (metadata: Int, artwork: Int) {
        (metadataStarts, artworkStarts)
    }

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

    func waitForMetadataStarts(_ count: Int) async -> Bool {
        for _ in 0 ..< 1000 {
            if metadataStarts >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

/// Mirrors the production C bridge: cancellation completes a read whose callback never arrived.
/// `cancelledArtwork` adds an adversarial late value to prove the timeout result still wins.
private actor CancellationSafeStalledArtworkReader {
    private let cancelledArtwork: Data?
    private let nextArtwork: Data?
    private var reads = 0

    init(cancelledArtwork: Data? = nil, nextArtwork: Data? = nil) {
        self.cancelledArtwork = cancelledArtwork
        self.nextArtwork = nextArtwork
    }

    func read() async -> Data? {
        reads += 1
        guard reads == 1 else { return nextArtwork }
        do {
            try await Task.sleep(for: .seconds(60))
            return nil
        } catch {
            await Task.yield()
            return cancelledArtwork
        }
    }

    func waitForReads(_ count: Int) async -> Bool {
        for _ in 0 ..< 1000 {
            if reads >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
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
