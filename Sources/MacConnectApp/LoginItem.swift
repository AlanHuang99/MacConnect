import AppKit
import Foundation
import MacConnectCore
import ServiceManagement

/// Wraps `SMAppService.mainApp` so the rest of the app sees a small,
/// throwing surface instead of the raw service status enum.
///
/// SMAppService requires the running .app bundle to be in a registered
/// location (typically /Applications). Ad-hoc dev builds launched out of
/// `build/` will fail with `Operation not permitted`; the caller must
/// surface that to the user rather than crashing.
///
/// Both `register()` and the status read are synchronous XPC calls to
/// `launchd`; first invocation on a freshly-installed app can take a
/// noticeable amount of time. Every entry point here runs off the main
/// actor so SwiftUI doesn't freeze while we wait.
public enum LoginItem {
    /// Returns the current status from `launchd`. Synchronous XPC —
    /// **call from a background context only**. UI code should observe
    /// the cached value via `LoginItemController` instead.
    public static func isEnabledBlocking() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            try service.register()
            Log.app.info("Registered MacConnect as a login item")
        } else {
            try service.unregister()
            Log.app.info("Unregistered MacConnect login item")
        }
    }

    /// Heuristic: the .app got translocated to a sandboxed read-only
    /// staging location because it was launched from a quarantined source
    /// (DMG, ZIP) instead of being copied to /Applications first.
    /// `SMAppService.mainApp.register()` cannot succeed from there.
    public static func isAppTranslocated() -> Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/")
            || path.contains("/AppTranslocation-")
    }
}

/// SwiftUI-observable wrapper around `LoginItem`. The cached `isEnabled`
/// is read once on creation, then only refreshed when we explicitly ask
/// for it (after a successful register / unregister). The SwiftUI Toggle
/// no longer fires a synchronous XPC call on every view re-render.
@MainActor
public final class LoginItemController: ObservableObject {
    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var isBusy: Bool = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var isTranslocated: Bool = false

    public init() {
        self.isTranslocated = LoginItem.isAppTranslocated()
        refresh()
    }

    /// Refresh `isEnabled` from launchd off the main thread.
    public func refresh() {
        Task.detached(priority: .utility) {
            let enabled = LoginItem.isEnabledBlocking()
            await MainActor.run { [weak self] in
                self?.isEnabled = enabled
            }
        }
    }

    /// Toggle the login-item state. Runs `SMAppService.register/unregister`
    /// off the main actor so SwiftUI stays responsive while launchd
    /// processes the request.
    public func setEnabled(_ desired: Bool) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            let errorMessage: String?
            do {
                try LoginItem.setEnabled(desired)
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't \(desired ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            }
            let observed = LoginItem.isEnabledBlocking()
            await MainActor.run { [weak self] in
                guard let self else { return }
                isEnabled = observed
                lastError = errorMessage
                isBusy = false
            }
        }
    }
}
