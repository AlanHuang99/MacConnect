import AppKit
import SwiftUI
import MacConnectCore
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerPlugins()
        configureNotificationCenter()
        startNetworking()
        setupStatusItem()
        registerServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tears down the broadcast timer, UDP/mDNS listeners, all live
        // per-device channels, and the TCP listener. Without this, AppKit
        // killed the process while NIO event loops still had open sockets
        // — fine for the OS, noisy in logs.
        LanLinkProvider.shared.stop()
    }

    private func registerServices() {
        NSApp.servicesProvider = self
        // Tell Launch Services to re-scan our Info.plist for NSServices, so
        // a freshly installed/upgraded build appears in the Services menu
        // without requiring a logout.
        NSUpdateDynamicServices()
    }

    private func registerPlugins() {
        let registry = PluginRegistry.shared
        registry.register(PingPlugin())
        registry.register(ClipboardPlugin())
        registry.register(NotificationPlugin())
        registry.register(FindMyPhonePlugin())
        registry.register(MprisPlugin())
        registry.register(BatteryPlugin())
        registry.register(SharePlugin())
    }

    private func configureNotificationCenter() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Notifier.registerCategories()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.app.notice("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                Log.app.notice("Notification authorization not granted")
            }
        }
    }

    private func startNetworking() {
        do {
            try LanLinkProvider.shared.start()
        } catch {
            Log.app.error("Failed to start networking: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right", accessibilityDescription: "MacConnect")
            button.action = #selector(togglePopover)
            button.target = self
        }
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 500)
        popover.contentViewController = NSHostingController(rootView: StatusView())
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
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
        userData: String?,
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
        Log.plugin.info("Queued \(urls.count, privacy: .public) file(s) via Services menu to \(target.id, privacy: .public)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banners even when the menu-bar app is "active" (popover open).
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
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
