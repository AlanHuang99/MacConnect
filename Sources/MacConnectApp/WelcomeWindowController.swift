import AppKit
import MacConnectCore
import Network
import SwiftUI
import UserNotifications

/// First-run welcome window. Without this, launching a menu-bar-only app
/// from /Applications looks like nothing happened: there's no Dock icon,
/// no menu-bar focus, and the user spends a minute hunting for the app
/// before realising it's already running.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    /// One-shot UserDefaults key. Bumped if we ever materially change the
    /// onboarding flow so existing users see the new content once.
    private static let userDefaultsKey = "macconnect.welcomeShownVersion"
    private static let currentVersion = 1

    private var window: NSWindow?
    var onClose: (() -> Void)?

    static func shouldShow() -> Bool {
        UserDefaults.standard.integer(forKey: userDefaultsKey) < currentVersion
    }

    func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to MacConnect"
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(rootView: WelcomeView(onFinish: { [weak self] in
            self?.dismiss()
        }))
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }

    private func dismiss() {
        UserDefaults.standard.set(Self.currentVersion, forKey: Self.userDefaultsKey)
        window?.close()
    }

    func windowWillClose(_: Notification) {
        // Set the seen-version here too in case the user closes the window
        // via the red traffic light without pressing "Get Started".
        UserDefaults.standard.set(Self.currentVersion, forKey: Self.userDefaultsKey)
        onClose?()
    }
}

private struct WelcomeView: View {
    var onFinish: () -> Void
    @State private var notificationsGranted: Bool?
    @State private var localNetworkProbed = false
    @State private var translocated: Bool = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 4)

            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(.sRGB, red: 0.18, green: 0.41, blue: 0.78, opacity: 1),
                                 Color(.sRGB, red: 0.10, green: 0.22, blue: 0.55, opacity: 1)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 88, height: 88)
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white)
            }

            Text("Welcome to MacConnect")
                .font(.title2.weight(.semibold))

            VStack(spacing: 6) {
                Text("MacConnect lives in your menu bar.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                    Text("Look for the radio-waves icon at the top of your screen.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if translocated {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Move MacConnect to Applications", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                    Text(
                        "MacConnect is running from a temporary location. Drag MacConnect.app into your Applications folder and relaunch so Launch-at-Login and auto-updates work correctly."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 10) {
                permissionRow(
                    icon: "bell.badge",
                    title: "Notifications",
                    state: notificationsState,
                    action: requestNotifications
                )
                permissionRow(
                    icon: "wifi",
                    title: "Local network",
                    state: localNetworkProbed ? .probed : .unknown,
                    action: probeLocalNetwork
                )
                Text(
                    "MacConnect uses both to discover nearby devices and to notify you when a peer sends a ping or a file."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
                onFinish()
            } label: {
                Text("Get Started")
                    .frame(minWidth: 140)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Spacer().frame(height: 8)
        }
        .padding(.horizontal, 16)
        .frame(width: 460, height: 540)
        .onAppear {
            translocated = Self.isTranslocated()
            refreshNotificationStatus()
        }
    }

    private enum PermissionState {
        case unknown
        case granted
        case denied
        case probed
    }

    private var notificationsState: PermissionState {
        switch notificationsGranted {
        case .some(true): .granted
        case .some(false): .denied
        case .none: .unknown
        }
    }

    private func permissionRow(icon: String, title: String, state: PermissionState,
                               action: @escaping () -> Void) -> some View
    {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(title)
            Spacer()
            switch state {
            case .granted, .probed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .unknown:
                Button("Allow", action: action)
                    .controlSize(.small)
            }
        }
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // Extract the Sendable bit on the callback's own thread; do
            // not capture the non-Sendable UNNotificationSettings across
            // to the main actor.
            let resolved: Bool? = {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: return true
                case .denied: return false
                case .notDetermined: return nil
                @unknown default: return nil
                }
            }()
            DispatchQueue.main.async {
                notificationsGranted = resolved
            }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                notificationsGranted = granted
            }
        }
    }

    /// macOS gates UDP broadcast / Bonjour behind the Local Network
    /// privacy prompt on macOS 14+. We drive a dedicated NWConnection
    /// here rather than calling `LanLinkProvider.refresh()`, because
    /// the provider's broadcast path is a no-op until its server
    /// channel is bound — and provider startup runs in a detached task,
    /// so it may not be ready when the user clicks Allow. This way the
    /// system prompt surfaces immediately and we only mark the row
    /// complete once the send actually fires (or definitively fails).
    private func probeLocalNetwork() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("255.255.255.255"),
            port: NWEndpoint.Port(rawValue: MacConnectCore.Settings.udpPort)!
        )
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let connection = NWConnection(to: endpoint, using: params)
        // The Network framework binds lazily; force the prompt by
        // moving to `.ready` and then sending a single zero byte —
        // a malformed packet that any peer drops, but enough to make
        // macOS classify the app as touching the local network.
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data([0]), completion: .contentProcessed { _ in
                    DispatchQueue.main.async { localNetworkProbed = true }
                    connection.cancel()
                })
            case .failed, .cancelled:
                DispatchQueue.main.async { localNetworkProbed = true }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    static func isTranslocated() -> Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/")
            || path.contains("/AppTranslocation-")
    }
}
