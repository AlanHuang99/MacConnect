import AppKit
import Combine
import MacConnectCore
import SwiftUI
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverEventMonitor: Any?
    private var welcomeWindowController: WelcomeWindowController?
    private var toastSubscription: AnyCancellable?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_: Notification) {
        DiagnosticLog.shared.record("app", "launch")
        // Order matters: the status item must exist BEFORE any heavy work
        // so the user always has a way to interact with (and quit) the app
        // even if networking, openssl, or Launch Services are slow. With
        // `LSUIElement=true` there's no Dock icon — losing the status item
        // = losing the entire UI.
        registerPlugins()
        setupStatusItem()
        configureNotificationCenter()
        showWelcomeWindowIfFirstRun()

        // Networking touches openssl (subprocess), NIO bind, and Bonjour —
        // any of which can stall on first launch (cold launchd, MDM,
        // multicast permission gate). Move off the main thread so the UI
        // stays responsive.
        Task.detached(priority: .userInitiated) {
            do {
                try LanLinkProvider.shared.start()
            } catch {
                Log.app.error("Failed to start networking: \(error.localizedDescription, privacy: .public)")
            }
        }

    }

    func applicationWillTerminate(_: Notification) {
        // Time-boxed teardown. Each TCP graceful close requires a peer
        // FIN-ACK; sleeping phones / dead Wi-Fi can leave the kernel
        // waiting the full close timeout. We give all closes a budget,
        // then let the kernel reap any stragglers when the process exits.
        DiagnosticLog.shared.recordSync("app", "terminate-begin")
        PayloadTransport.cancelAll(reason: "Application is quitting")
        LanLinkProvider.shared.stop(deadline: .now() + 0.75)
        NIOTransport.shared.shutdown(deadline: .now() + 0.5)
        DiagnosticLog.shared.recordSync("app", "terminate-end")
    }

    private func showWelcomeWindowIfFirstRun() {
        guard WelcomeWindowController.shouldShow() else { return }
        let controller = WelcomeWindowController()
        controller.onClose = { [weak self] in
            self?.welcomeWindowController = nil
            NSApp.setActivationPolicy(.accessory)
        }
        welcomeWindowController = controller
        NSApp.setActivationPolicy(.regular)
        controller.show()
    }

    private func registerPlugins() {
        let registry = PluginRegistry.shared
        registry.register(PingPlugin())
        registry.register(ClipboardPlugin())
        registry.register(BatteryPlugin())
        registry.register(SharePlugin())
    }

    private func configureNotificationCenter() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Notifier.registerCategories()
        // On a true first run, the welcome window owns the first
        // authorization prompt so it has visible context. Asking here
        // anyway would race the welcome window and surface the system
        // dialog before the user sees any MacConnect UI — defeating the
        // "prompt with context" sequencing.
        if WelcomeWindowController.shouldShow() { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.app
                    .notice(
                        "Notification authorization request failed: \(error.localizedDescription, privacy: .public)"
                    )
            } else if !granted {
                Log.app.notice("Notification authorization not granted")
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "iphone.radiowaves.left.and.right",
                accessibilityDescription: "MacConnect"
            )
            button.action = #selector(togglePopover)
            button.target = self
        }
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.contentViewController = NSHostingController(rootView: StatusView())
        observeTransferToasts()
    }

    /// When a command publishes a toast, flash the popover open if it's
    /// closed and the user is still focused on MacConnect. This gives
    /// immediate feedback even when system notifications are denied.
    private func observeTransferToasts() {
        toastSubscription = TransferStore.shared.$toast
            .compactMap { $0 }
            .sink { [weak self] _ in
                self?.flashPopoverForToast()
            }
    }

    private func flashPopoverForToast() {
        guard let button = statusItem.button else { return }
        guard !popover.isShown else { return }
        // Only auto-open if the user is still on us. If they've Cmd-
        // Tabbed away to another app, surfacing a popover would be a
        // jarring focus-steal.
        guard NSApp.isActive else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installPopoverDismissMonitor()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            // Do NOT call NSApp.activate(ignoringOtherApps: true) — it
            // pulls our accessory app frontmost and on recent macOS
            // suppresses the .transient outside-click dismissal the user
            // expects. The popover becomes key on its own.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installPopoverDismissMonitor()
        }
    }

    /// Belt-and-braces for `.transient` dismissal: a global mouse-down
    /// monitor closes the popover if the user clicks anywhere outside
    /// our app. The system's own outside-click handling generally fires,
    /// but this guarantees the behaviour across macOS versions.
    private func installPopoverDismissMonitor() {
        if popoverEventMonitor != nil { return }
        popoverEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
        if let monitor = popoverEventMonitor {
            NSEvent.removeMonitor(monitor)
            popoverEventMonitor = nil
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banners even when the menu-bar app is "active" (popover open).
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive _: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }
}
