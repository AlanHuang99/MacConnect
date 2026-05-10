import AppKit
import SwiftUI
import MacConnectCore
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        requestNotificationAuthorization()
        startNetworking()
        setupStatusItem()
    }

    private func registerPlugins() {
        let registry = PluginRegistry.shared
        registry.register(PingPlugin())
        registry.register(ClipboardPlugin())
        registry.register(NotificationPlugin())
        registry.register(FindMyPhonePlugin())
        registry.register(MprisPlugin())
        registry.register(SharePlugin())
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
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
}
