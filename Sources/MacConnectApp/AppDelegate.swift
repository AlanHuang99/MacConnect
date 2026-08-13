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
    private var wakeObserver: NSObjectProtocol?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Order matters: the status item must exist BEFORE any heavy work
        // so the user always has a way to interact with (and quit) the app
        // even if networking, openssl, or Launch Services are slow. With
        // `LSUIElement=true` there's no Dock icon — losing the status item
        // = losing the entire UI.
        registerPlugins()
        setupStatusItem()
        configureNotificationCenter()
        showWelcomeWindowIfFirstRun()

        // Boot the updater at launch so a user who has opted into automatic
        // checks gets one shortly after start. No-op in the App Store build
        // (UpdaterController is an inert shell without Sparkle).
        _ = UpdaterController.shared

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

        observeSystemWake()

        // Periodic liveness reconciliation re-derives reachability from the
        // last-packet time on the wall clock, which keeps counting across
        // sleep. This catches the peer that vanished during display sleep /
        // screen saver / Doze — when no socket-close, wake, or path-change
        // event fires — so it stops showing stale "online" + battery +
        // now-playing instead of waiting for a restart.
        DeviceManager.shared.startReconciliation()

        // Services rescan is a full Launch Services walk; defer it a beat
        // and only run when the Info.plist NSServices block actually
        // changed since the last launch.
        Task.detached(priority: .utility) {
            await MainActor.run { Self.registerServicesIfNeeded() }
        }
    }

    func applicationWillTerminate(_: Notification) {
        DeviceManager.shared.stopReconciliation()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        // Time-boxed teardown. Each TCP graceful close requires a peer
        // FIN-ACK; sleeping phones / dead Wi-Fi can leave the kernel
        // waiting the full close timeout. We give all closes a budget,
        // then let the kernel reap any stragglers when the process exits.
        LanLinkProvider.shared.stop(deadline: .now() + 0.75)
        NIOTransport.shared.shutdown(deadline: .now() + 0.5)
    }

    /// Rebuild discovery when the Mac wakes. On sleep the UDP listener, mDNS
    /// browser, and broadcast socket stop delivering on the now-stale
    /// interfaces and never recover on their own, so peers became invisible
    /// until the app was restarted. `restartDiscovery()` is debounced and
    /// no-ops until networking has started, so an early or duplicate wake is
    /// harmless. The NWPathMonitor inside LanLinkProvider catches the same
    /// event from the network side; both firing just collapses into one
    /// rebuild. Sleep/wake posts on `NSWorkspace`'s own notification center,
    /// not `NotificationCenter.default`.
    private func observeSystemWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Log.app.notice("System woke; rebuilding discovery")
            LanLinkProvider.shared.restartDiscovery()
        }
    }

    private static func registerServicesIfNeeded() {
        NSApp.servicesProvider = sharedDelegate
        // Hash the NSServices array; only rescan when it changed. A full
        // NSUpdateDynamicServices() call is multi-second on first launch
        // and was running every cold start in 0.2.x.
        let fingerprint = Self.servicesFingerprint()
        let key = "macconnect.servicesFingerprint"
        if UserDefaults.standard.string(forKey: key) == fingerprint {
            return
        }
        NSUpdateDynamicServices()
        UserDefaults.standard.set(fingerprint, forKey: key)
    }

    private static var sharedDelegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    private static func servicesFingerprint() -> String {
        // Stable hash of the NSServices array. If it ever stops matching
        // the value in Info.plist, the next launch will trigger a rescan.
        guard let services = Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [Any],
              let data = try? PropertyListSerialization.data(fromPropertyList: services, format: .binary, options: 0)
        else {
            return "missing"
        }
        return data.base64EncodedString()
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
        registry.register(NotificationPlugin())
        registry.register(FindMyPhonePlugin())
        registry.register(MprisPlugin())
        registry.register(SystemVolumePlugin())
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
            button.image = Self.statusItemIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.contentViewController = NSHostingController(rootView: StatusView())
        observeTransferToasts()
    }

    /// The real app icon, sized for the menu bar, so the status item
    /// matches the Dock / Finder branding — the previous SF Symbol looked
    /// like a different app next to the actual icon. Colored on purpose
    /// (not a template): the icon is a solid blue tile whose glyph reads
    /// fine at 18 pt in both light and dark menu bars, and templating a
    /// filled tile would render it as a featureless square. Copy before
    /// resizing — `applicationIconImage` is a shared instance and resizing
    /// it in place would shrink the icon everywhere else it appears.
    private static func statusItemIcon() -> NSImage? {
        guard let icon = NSApp.applicationIconImage.copy() as? NSImage else {
            // Fallback (e.g. running the bare executable without a bundle):
            // the old symbol beats an empty status item.
            return NSImage(
                systemSymbolName: "iphone.radiowaves.left.and.right",
                accessibilityDescription: "MacConnect"
            )
        }
        icon.size = NSSize(width: 18, height: 18)
        icon.accessibilityDescription = "MacConnect"
        return icon
    }

    /// When SharePlugin publishes a Toast (via TransferStore), flash the
    /// popover open if it's closed and the user is still focused on
    /// MacConnect. The popover renders the toast banner so the user sees
    /// "Sent X to Y" / "Send failed" even when system notifications are
    /// denied (true on ad-hoc-signed dev builds, and any time the user
    /// chose Don't Allow at the welcome prompt).
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

    /// Internal (not private) because StatusView calls it before
    /// presenting the file picker: the `.transient` popover and its
    /// global dismiss monitor fight any modal panel for key-window
    /// status, so both must be torn down before the panel comes up.
    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
        if let monitor = popoverEventMonitor {
            NSEvent.removeMonitor(monitor)
            popoverEventMonitor = nil
        }
    }

    // MARK: - Services menu handler

    /// Invoked by macOS when the user picks "Send via MacConnect" from a
    /// file's Services submenu. Signature is dictated by the NSServices
    /// API; the method name (sans Swift translation) is referenced from
    /// the NSMessage key in Info.plist as `sendFileToDevice`.
    @objc
    func sendFileToDevice(
        _ pasteboard: NSPasteboard,
        userData _: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files in selection" as NSString
            return
        }
        Task { @MainActor in
            await chooseDeviceAndSend(urls: urls)
        }
    }

    @MainActor
    private func chooseDeviceAndSend(urls: [URL]) async {
        NSApp.activate(ignoringOtherApps: true)

        let candidates = DeviceManager.shared.deviceList()
            .filter { $0.isPaired && $0.isReachable }
        if candidates.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No paired devices online"
            alert.informativeText = "Pair and connect a device in MacConnect, then try again."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Send to which device?"
        alert.informativeText = urls.count == 1
            ? urls[0].lastPathComponent
            : "\(urls.count) files"
        for device in candidates {
            alert.addButton(withTitle: device.name)
        }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        let firstDeviceCode = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let idx = response.rawValue - firstDeviceCode
        guard idx >= 0, idx < candidates.count else { return }
        let target = candidates[idx]
        for url in urls {
            SharePlugin.sendFile(url, to: target)
        }
        Log.plugin
            .info("Queued \(urls.count, privacy: .public) file(s) via Services menu to \(target.id, privacy: .public)")
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
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let deviceId = userInfo[Notifier.userInfoDeviceId] as? String
        let replyId = userInfo[Notifier.userInfoRequestReplyId] as? String
        let userText = (response as? UNTextInputNotificationResponse)?.userText

        Task { @MainActor in
            defer { completionHandler() }
            guard actionId == Notifier.replyActionIdentifier,
                  let deviceId, let replyId,
                  let userText, !userText.isEmpty,
                  let device = DeviceManager.shared.devices[deviceId]
            else { return }
            guard device.isReachable else {
                Log.plugin.notice("Drop notification reply for offline device \(deviceId, privacy: .public)")
                return
            }
            device.send(NotificationPlugin.replyPacket(requestReplyId: replyId, message: userText))
            Log.plugin.info("Sent notification reply to \(deviceId, privacy: .public)")
        }
    }
}
