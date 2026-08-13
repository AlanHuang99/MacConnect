import Darwin
@preconcurrency import Foundation

struct MediaRemoteState: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var isPlaying: Bool
    var isAvailable: Bool
    var lengthMs: Int64?
    var positionMs: Int64?

    static let unavailable = MediaRemoteState(
        title: nil,
        artist: nil,
        album: nil,
        isPlaying: false,
        isAvailable: false,
        lengthMs: nil,
        positionMs: nil
    )
}

struct MediaRemoteMetadataKeys: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var duration: String?
    var elapsedTime: String?
}

enum MediaRemoteMetadataMapper {
    static func map(
        _ information: [String: Any],
        isPlaying: Bool,
        keys: MediaRemoteMetadataKeys
    ) -> MediaRemoteState {
        MediaRemoteState(
            title: text(information, key: keys.title),
            artist: text(information, key: keys.artist),
            album: text(information, key: keys.album),
            isPlaying: isPlaying,
            isAvailable: true,
            lengthMs: milliseconds(information, key: keys.duration),
            positionMs: milliseconds(information, key: keys.elapsedTime)
        )
    }

    private static func text(_ information: [String: Any], key: String?) -> String? {
        guard let key, let value = information[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func milliseconds(_ information: [String: Any], key: String?) -> Int64? {
        guard let key, let number = information[key] as? NSNumber else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return Int64((seconds * 1_000).rounded())
    }
}

@MainActor
protocol MediaRemoteControlling: AnyObject {
    var state: MediaRemoteState { get }
    var onChange: (() -> Void)? { get set }

    func play()
    func pause()
    func togglePlayPause()
}

@MainActor
final class MediaRemoteBridge: MediaRemoteControlling {
    private enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
    }

    private typealias GetNowPlayingInfo = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (CFDictionary?) -> Void
    ) -> Void
    private typealias GetIsPlaying = @convention(c) (
        DispatchQueue,
        @escaping @convention(block) (Bool) -> Void
    ) -> Void
    private typealias SendCommand = @convention(c) (Int, CFDictionary?) -> Bool
    private typealias RegisterNotifications = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterNotifications = @convention(c) () -> Void

    private final class Symbols: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer
        let getNowPlayingInfo: GetNowPlayingInfo
        let getIsPlaying: GetIsPlaying
        let sendCommand: SendCommand
        let registerNotifications: RegisterNotifications
        let unregisterNotifications: UnregisterNotifications
        let infoDidChange: Notification.Name
        let playingDidChange: Notification.Name
        let metadataKeys: MediaRemoteMetadataKeys

        init?() {
            let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }

            guard
                let getNowPlayingInfo: GetNowPlayingInfo = Self.function(
                    handle,
                    named: "MRMediaRemoteGetNowPlayingInfo"
                ),
                let getIsPlaying: GetIsPlaying = Self.function(
                    handle,
                    named: "MRMediaRemoteGetNowPlayingApplicationIsPlaying"
                ),
                let sendCommand: SendCommand = Self.function(
                    handle,
                    named: "MRMediaRemoteSendCommand"
                ),
                let registerNotifications: RegisterNotifications = Self.function(
                    handle,
                    named: "MRMediaRemoteRegisterForNowPlayingNotifications"
                ),
                let unregisterNotifications: UnregisterNotifications = Self.function(
                    handle,
                    named: "MRMediaRemoteUnregisterForNowPlayingNotifications"
                ),
                let infoDidChange = Self.string(
                    handle,
                    named: "kMRMediaRemoteNowPlayingInfoDidChangeNotification"
                ),
                let playingDidChange = Self.string(
                    handle,
                    named: "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"
                )
            else {
                dlclose(handle)
                return nil
            }

            self.handle = handle
            self.getNowPlayingInfo = getNowPlayingInfo
            self.getIsPlaying = getIsPlaying
            self.sendCommand = sendCommand
            self.registerNotifications = registerNotifications
            self.unregisterNotifications = unregisterNotifications
            self.infoDidChange = Notification.Name(infoDidChange)
            self.playingDidChange = Notification.Name(playingDidChange)
            self.metadataKeys = MediaRemoteMetadataKeys(
                title: Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoTitle"),
                artist: Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoArtist"),
                album: Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoAlbum"),
                duration: Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoDuration"),
                elapsedTime: Self.string(handle, named: "kMRMediaRemoteNowPlayingInfoElapsedTime")
            )
        }

        deinit {
            dlclose(handle)
        }

        private static func function<T>(_ handle: UnsafeMutableRawPointer, named name: String) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: T.self)
        }

        private static func string(_ handle: UnsafeMutableRawPointer, named name: String) -> String? {
            guard let symbol = dlsym(handle, name) else { return nil }
            let pointer = symbol.assumingMemoryBound(to: Unmanaged<CFString>?.self)
            return pointer.pointee?.takeUnretainedValue() as String?
        }
    }

    private let symbols: Symbols?
    private var observers: [NSObjectProtocol] = []

    private(set) var state: MediaRemoteState = .unavailable
    var onChange: (() -> Void)?

    init() {
        guard let symbols = Symbols() else {
            self.symbols = nil
            Log.plugin.error("MediaRemote is unavailable; local playback control disabled")
            return
        }

        self.symbols = symbols
        state.isAvailable = true
        symbols.registerNotifications(.main)
        observe(symbols.infoDidChange)
        observe(symbols.playingDidChange)
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        symbols?.unregisterNotifications()
    }

    func play() {
        send(.play)
    }

    func pause() {
        send(.pause)
    }

    func togglePlayPause() {
        send(.togglePlayPause)
    }

    private func observe(_ name: Notification.Name) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    private func send(_ command: Command) {
        guard let symbols else { return }
        _ = symbols.sendCommand(command.rawValue, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let symbols else { return }

        symbols.getNowPlayingInfo(.main) { [weak self] dictionary in
            let information = dictionary as NSDictionary? as? [String: Any] ?? [:]
            Task { @MainActor in
                guard let self, let symbols = self.symbols else { return }
                self.state = MediaRemoteMetadataMapper.map(
                    information,
                    isPlaying: self.state.isPlaying,
                    keys: symbols.metadataKeys
                )
                self.onChange?()
            }
        }

        symbols.getIsPlaying(.main) { [weak self] isPlaying in
            Task { @MainActor in
                guard let self else { return }
                self.state.isPlaying = isPlaying
                self.state.isAvailable = true
                self.onChange?()
            }
        }
    }
}
