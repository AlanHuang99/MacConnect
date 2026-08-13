import Darwin
@preconcurrency import Foundation

struct MediaRemoteState: Equatable {
    var playerName: String?
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

enum MediaRemoteReadStrategy: Equatable {
    case legacyCallbacks
    case automationHost

    static var current: MediaRemoteReadStrategy {
        forVersion(ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func forVersion(_ version: OperatingSystemVersion) -> MediaRemoteReadStrategy {
        if version.majorVersion > 15 ||
            (version.majorVersion == 15 && version.minorVersion >= 4)
        {
            return .automationHost
        }
        return .legacyCallbacks
    }
}

struct MediaRemoteAutomationSnapshot: Decodable {
    let available: Bool
    let playerName: String?
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsed: Double?
    let rate: Double?

    static func decode(_ data: Data) throws -> MediaRemoteState {
        let snapshot = try JSONDecoder().decode(MediaRemoteAutomationSnapshot.self, from: data)
        guard snapshot.available else { return .unavailable }

        return MediaRemoteState(
            playerName: clean(snapshot.playerName),
            title: clean(snapshot.title),
            artist: clean(snapshot.artist),
            album: clean(snapshot.album),
            isPlaying: snapshot.rate.map { $0 > 0 } ?? false,
            isAvailable: true,
            lengthMs: milliseconds(snapshot.duration),
            positionMs: milliseconds(snapshot.elapsed)
        )
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func milliseconds(_ seconds: Double?) -> Int64? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return Int64((seconds * 1000).rounded())
    }
}

private enum MediaRemoteAutomationReader {
    private static let script = #"""
    ObjC.import("AppKit");
    const bundle = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/");
    bundle.load;
    const request = $.NSClassFromString("MRNowPlayingRequest");
    const item = request.localNowPlayingItem;
    if (!item) {
        JSON.stringify({available: false});
    } else {
        const info = item.nowPlayingInfo;
        const path = request.localNowPlayingPlayerPath;
        const client = path ? path.client : null;
        const value = (key) => {
            const result = info.valueForKey(key);
            return result ? ObjC.unwrap(result) : null;
        };
        JSON.stringify({
            available: true,
            playerName: client && client.displayName ? ObjC.unwrap(client.displayName) : null,
            title: value("kMRMediaRemoteNowPlayingInfoTitle"),
            artist: value("kMRMediaRemoteNowPlayingInfoArtist"),
            album: value("kMRMediaRemoteNowPlayingInfoAlbum"),
            duration: value("kMRMediaRemoteNowPlayingInfoDuration"),
            elapsed: value("kMRMediaRemoteNowPlayingInfoElapsedTime"),
            rate: value("kMRMediaRemoteNowPlayingInfoPlaybackRate")
        });
    }
    """#

    static func read() async -> MediaRemoteState? {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return try MediaRemoteAutomationSnapshot.decode(data)
            } catch {
                return nil
            }
        }.value
    }
}

struct MediaRemoteMetadataKeys {
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
        return Int64((seconds * 1000).rounded())
    }
}

struct MediaRemoteRefreshGeneration {
    private var value: UInt = 0

    mutating func begin() -> UInt {
        value &+= 1
        return value
    }

    func isCurrent(_ candidate: UInt) -> Bool {
        candidate == value
    }
}

@MainActor
protocol MediaRemoteControlling: AnyObject {
    var state: MediaRemoteState { get }
    var onChange: (() -> Void)? { get set }

    func play()
    func pause()
    func togglePlayPause()
    func previous()
    func next()
}

@MainActor
final class MediaRemoteBridge: MediaRemoteControlling {
    private enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case next = 4
        case previous = 5
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
    private let readStrategy: MediaRemoteReadStrategy
    private var observers: [NSObjectProtocol] = []
    private var refreshGeneration = MediaRemoteRefreshGeneration()
    private var pollingTask: Task<Void, Never>?
    private var didLogAutomationFailure = false
    private var registeredForNotifications = false

    private(set) var state: MediaRemoteState = .unavailable
    var onChange: (() -> Void)?

    init(readStrategy: MediaRemoteReadStrategy = .current) {
        self.readStrategy = readStrategy
        guard let symbols = Symbols() else {
            self.symbols = nil
            Log.plugin.error("MediaRemote is unavailable; local playback control disabled")
            return
        }

        self.symbols = symbols
        switch readStrategy {
        case .legacyCallbacks:
            state.isAvailable = true
            symbols.registerNotifications(.main)
            registeredForNotifications = true
            observe(symbols.infoDidChange)
            observe(symbols.playingDidChange)
            refresh()
        case .automationHost:
            startPolling()
        }
    }

    deinit {
        pollingTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        if registeredForNotifications {
            symbols?.unregisterNotifications()
        }
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

    func previous() {
        send(.previous)
    }

    func next() {
        send(.next)
    }

    private func observe(_ name: Notification.Name) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        })
    }

    private func send(_ command: Command) {
        guard let symbols else { return }
        if !symbols.sendCommand(command.rawValue, nil) {
            Log.plugin.error("MediaRemote rejected playback command \(command.rawValue, privacy: .public)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let symbols else { return }
        let generation = refreshGeneration.begin()

        if readStrategy == .automationHost {
            Task { [weak self] in
                let updatedState = await MediaRemoteAutomationReader.read()
                guard let self, self.refreshGeneration.isCurrent(generation) else { return }
                guard let updatedState else {
                    if !self.didLogAutomationFailure {
                        Log.plugin.error("MediaRemote automation read failed")
                        self.didLogAutomationFailure = true
                    }
                    return
                }
                self.didLogAutomationFailure = false
                guard updatedState != self.state else { return }
                self.state = updatedState
                self.onChange?()
            }
            return
        }

        symbols.getNowPlayingInfo(.main) { [weak self] dictionary in
            let information = dictionary as NSDictionary? as? [String: Any] ?? [:]
            Task { @MainActor in
                guard let self,
                      self.refreshGeneration.isCurrent(generation),
                      let symbols = self.symbols
                else { return }
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
                guard let self, self.refreshGeneration.isCurrent(generation) else { return }
                self.state.isPlaying = isPlaying
                self.state.isAvailable = true
                self.onChange?()
            }
        }
    }

    private func startPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
