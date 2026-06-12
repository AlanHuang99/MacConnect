import Combine
import Foundation
#if SPARKLE
import Sparkle
#endif

/// Wraps Sparkle's standard updater as an `ObservableObject` so the Settings
/// UI can bind to `canCheckForUpdates` and enable/disable the button while a
/// check is in flight.
///
/// The type exists in BOTH builds. All Sparkle-specific code is gated behind
/// `#if SPARKLE` (defined only when `MACCONNECT_SPARKLE=1`, i.e. the Direct
/// channel). In the App Store build it compiles to an inert shell with
/// `isSupported == false`, so the Settings panel simply hides the update
/// section — the App Store delivers updates there, and bundling Sparkle would
/// get the app rejected. See `Package.swift` and the README's "Distribution
/// channels" section.
@MainActor
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    /// Mirrors `SPUUpdater.canCheckForUpdates`; drives the button's enabled
    /// state. Stays `false` in the Sparkle-free build.
    @Published var canCheckForUpdates = false

    /// `true` only in the Sparkle-linked (Direct) build. The Settings UI keys
    /// the entire update section off this.
    var isSupported: Bool {
        #if SPARKLE
        return true
        #else
        return false
        #endif
    }

    #if SPARKLE
    private let controller: SPUStandardUpdaterController
    #endif

    private init() {
        #if SPARKLE
        // startingUpdater: true boots the updater immediately. With
        // SUEnableAutomaticChecks=false in Info.plist, no background check is
        // scheduled until the user opts in via `automaticallyChecksForUpdates`.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        #endif
    }

    /// Show Sparkle's standard check-for-updates flow (progress, release
    /// notes, install, relaunch). No-op in the Sparkle-free build; the UI
    /// only ever calls it when `canCheckForUpdates` is true.
    func checkForUpdates() {
        #if SPARKLE
        controller.updater.checkForUpdates()
        #endif
    }

    /// User-facing toggle for scheduled background checks. Sparkle persists
    /// the choice in UserDefaults, overriding the Info.plist default once set.
    var automaticallyChecksForUpdates: Bool {
        get {
            #if SPARKLE
            return controller.updater.automaticallyChecksForUpdates
            #else
            return false
            #endif
        }
        set {
            #if SPARKLE
            controller.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }
}
