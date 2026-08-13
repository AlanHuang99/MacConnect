import Foundation

struct LocalMediaSnapshot: Equatable, Sendable {
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
