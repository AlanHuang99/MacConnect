@preconcurrency import Foundation

struct LocalMediaSnapshot: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var isPlaying: Bool
    var transportAvailable: Bool
    var volume: Int?
    var lengthMs: Int64?
    var positionMs: Int64?
}

@MainActor
protocol LocalMediaControlling: AnyObject {
    var snapshot: LocalMediaSnapshot { get }
    var onStateChange: (() -> Void)? { get set }

    func play()
    func pause()
    func togglePlayPause()
    func setVolume(_ percent: Int)
}

@MainActor
final class UnavailableLocalMediaController: LocalMediaControlling {
    let snapshot = LocalMediaSnapshot(
        title: nil,
        artist: nil,
        album: nil,
        isPlaying: false,
        transportAvailable: false,
        volume: nil,
        lengthMs: nil,
        positionMs: nil
    )

    var onStateChange: (() -> Void)?

    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func setVolume(_: Int) {}
}

@MainActor
final class SystemLocalMediaController: LocalMediaControlling {
    private let transport: MediaRemoteControlling
    private let volumeController: SystemVolumeProviding
    private let notificationDelay: TimeInterval
    private var pendingNotification: DispatchWorkItem?

    var onStateChange: (() -> Void)?

    var snapshot: LocalMediaSnapshot {
        let media = transport.state
        return LocalMediaSnapshot(
            title: media.title,
            artist: media.artist,
            album: media.album,
            isPlaying: media.isPlaying,
            transportAvailable: media.isAvailable,
            volume: volumeController.volume,
            lengthMs: media.lengthMs,
            positionMs: media.positionMs
        )
    }

    convenience init() {
        self.init(
            transport: MediaRemoteBridge(),
            volumeController: CoreAudioVolumeController()
        )
    }

    init(
        transport: MediaRemoteControlling,
        volumeController: SystemVolumeProviding,
        notificationDelay: TimeInterval = 0.1
    ) {
        self.transport = transport
        self.volumeController = volumeController
        self.notificationDelay = notificationDelay

        transport.onChange = { [weak self] in self?.scheduleNotification() }
        volumeController.onChange = { [weak self] in self?.scheduleNotification() }
    }

    deinit {
        pendingNotification?.cancel()
    }

    func play() {
        transport.play()
    }

    func pause() {
        transport.pause()
    }

    func togglePlayPause() {
        transport.togglePlayPause()
    }

    func setVolume(_ percent: Int) {
        volumeController.setVolume(percent)
    }

    private func scheduleNotification() {
        pendingNotification?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onStateChange?()
        }
        pendingNotification = work
        DispatchQueue.main.asyncAfter(deadline: .now() + notificationDelay, execute: work)
    }
}
