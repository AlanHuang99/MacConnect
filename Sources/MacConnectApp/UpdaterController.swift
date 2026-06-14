import Combine
import Foundation
#if SPARKLE
import AppKit
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
    /// Retained so Sparkle's weak `userDriverDelegate` reference stays alive
    /// for the life of the (singleton) updater. Brings the menu-bar app
    /// forward when Sparkle is about to show update UI — see the type's note.
    private let userDriver = AccessoryActivatingUserDriverDelegate()
    #endif

    private init() {
        #if SPARKLE
        // startingUpdater: true boots the updater immediately. With
        // SUEnableAutomaticChecks=false in Info.plist, no background check is
        // scheduled until the user opts in via `automaticallyChecksForUpdates`.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: userDriver
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

#if SPARKLE
/// Brings MacConnect forward when Sparkle is about to present update UI. The app
/// runs as an accessory (`LSUIElement`) with no Dock icon, so without an
/// explicit activation Sparkle's windows can open behind the frontmost app
/// where the user can't see or act on them — the reported "Install and
/// Relaunch" stuck-behind symptom.
///
/// Coverage uses the documented background-app path
/// (https://sparkle-project.org/documentation/gentle-reminders):
/// `supportsGentleScheduledUpdateReminders` opts in, and
/// `standardUserDriverWillHandleShowingUpdate` activates the app when an update
/// is first presented (scheduled or user-initiated). `standardUserDriverWillShowModalAlert`
/// covers the NSAlert dialogs (errors, "no update found"). Sparkle exposes no
/// delegate hook for the post-download status window, so if the user starts an
/// update and switches away mid-download, that final install prompt can still
/// surface behind other apps; the update-presentation and alert cases — which
/// is where this app actually got stuck — are handled.
///
/// Sparkle invokes the delegate on the main thread; we hop to the main actor
/// (matching the app's concurrency model) for the AppKit activation.
private final class AccessoryActivatingUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _: Bool,
        forUpdate _: SUAppcastItem,
        state _: SPUUserUpdateState
    ) {
        activateApp()
    }

    func standardUserDriverWillShowModalAlert() {
        activateApp()
    }

    private func activateApp() {
        Task { @MainActor in
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
#endif
