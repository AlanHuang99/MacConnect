import MacConnectCore
import SwiftUI

struct SettingsView: View {
    @Binding var isPresented: Bool
    @ObservedObject var settings: MacConnectCore.Settings = .shared
    @ObservedObject var transfers: TransferStore = .shared
    @ObservedObject private var updater = UpdaterController.shared
    @StateObject private var loginItem = LoginItemController()
    @State private var nameDraft: String = MacConnectCore.Settings.shared.deviceName

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HStack {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                Text("Settings", bundle: .module).font(.headline)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("This device") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Display name")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                TextField("Mac", text: $nameDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(commitName)
                                Button("Save", action: commitName)
                                    .disabled(nameDraft == settings.deviceName || nameDraft
                                        .trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            Text(
                                "Shown to other devices when broadcasting. Max 32 chars; no \" ' , ; : . ! ? ( ) [ ] < >"
                            )
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        Divider()
                        labelValue("Device ID", settings.deviceId)
                        labelValue("Protocol", "v\(Settings.protocolVersion)")
                        if let fp = CertificateService.shared.localFingerprint() {
                            labelValue("SHA-256", fp)
                        }
                    }

                    section("Startup") {
                        HStack {
                            Toggle("Launch at login", isOn: loginItemBinding)
                                .disabled(loginItem.isBusy || loginItem.isTranslocated)
                            if loginItem.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.leading, 4)
                            }
                            Spacer()
                        }
                        if loginItem.isTranslocated {
                            Text(
                                "MacConnect is running from a temporary location. Move MacConnect.app into your Applications folder and relaunch to use Launch at Login."
                            )
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        } else if let err = loginItem.lastError {
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        } else {
                            Text("App must be in /Applications and signed with Apple Developer ID for this to work.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    section("Plugins") {
                        let listing = PluginRegistry.shared.allPlugins
                        if listing.isEmpty {
                            Text("No plugins registered.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(listing, id: \.identifier) { plugin in
                                Toggle(plugin.displayName, isOn: pluginBinding(plugin.identifier))
                            }
                            Text("Disabled plugins are removed from the capabilities advertised to peers.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    section("Trusted devices") {
                        let trusted = settings.trustedDeviceIds.sorted()
                        if trusted.isEmpty {
                            Text("No paired devices yet.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(trusted, id: \.self) { id in
                                trustedDeviceRow(id: id)
                            }
                        }
                    }

                    section("Recent transfers") {
                        if transfers.recent.isEmpty {
                            Text("No transfers yet.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(transfers.recent) { transfer in
                                recentTransferRow(transfer)
                            }
                        }
                    }

                    if updater.isSupported {
                        section("Updates") {
                            HStack {
                                Button("Check for Updates…") { updater.checkForUpdates() }
                                    .disabled(!updater.canCheckForUpdates)
                                Spacer()
                            }
                            Toggle("Automatically check for updates", isOn: automaticUpdateBinding)
                            Text(
                                "Updates download from GitHub Releases and are verified with a built-in signature before installing."
                            )
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    section("About") {
                        VStack(alignment: .leading, spacing: 4) {
                            labelValue("Version", Self.appVersion)
                            labelValue("Build", Self.appBuild)
                            HStack {
                                Text("Source").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Link("github.com/AlanHuang99/MacConnect",
                                     destination: URL(string: "https://github.com/AlanHuang99/MacConnect")!)
                                    .font(.caption)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func recentTransferRow(_ transfer: TransferStore.Transfer) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon(for: transfer))
                .font(.caption)
                .foregroundStyle(color(for: transfer))
            VStack(alignment: .leading, spacing: 1) {
                Text(transfer.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(
                    "\(transfer.direction == .incoming ? "From" : "To") \(transfer.deviceName) · \(Self.formatBytes(transfer.totalBytes))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                if case .failed(let reason) = transfer.state {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private func icon(for transfer: TransferStore.Transfer) -> String {
        switch transfer.state {
        case .inProgress: "arrow.left.arrow.right.circle"
        case .completed: transfer.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(for transfer: TransferStore.Transfer) -> Color {
        switch transfer.state {
        case .inProgress: .secondary
        case .completed: .accentColor
        case .failed: .red
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    private func trustedDeviceRow(id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(id).font(.system(.caption, design: .monospaced))
                Spacer()
                Button("Forget") {
                    MacConnectCore.Settings.shared.unmarkTrusted(id)
                    MacConnectCore.Settings.shared.clearPerDevicePluginOverrides(forDevice: id)
                    CertificateService.shared.deleteRemoteCert(deviceId: id)
                    settings.objectWillChange.send()
                }
                .controlSize(.small)
            }
            if let fp = CertificateService.shared.fingerprint(forTrustedDeviceId: id) {
                Text("SHA-256 \(fp)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            DisclosureGroup("Plugin overrides") {
                ForEach(PluginRegistry.shared.allPlugins, id: \.identifier) { plugin in
                    Toggle(plugin.displayName, isOn: perDevicePluginBinding(plugin.identifier, deviceId: id))
                        .disabled(!MacConnectCore.Settings.shared.isPluginEnabled(plugin.identifier))
                        .font(.caption)
                }
                Text(
                    "Overrides on top of the global setting. Disabling here silently drops inbound packets from this peer for the plugin; outgoing capabilities still advertise it."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func perDevicePluginBinding(_ pluginId: String, deviceId: String) -> Binding<Bool> {
        Binding(
            get: { MacConnectCore.Settings.shared.isPluginEnabled(pluginId, forDevice: deviceId) },
            set: { newValue in
                MacConnectCore.Settings.shared.setPluginEnabled(pluginId, newValue, forDevice: deviceId)
            }
        )
    }

    private func pluginBinding(_ pluginId: String) -> Binding<Bool> {
        Binding(
            get: { MacConnectCore.Settings.shared.isPluginEnabled(pluginId) },
            set: { newValue in
                MacConnectCore.Settings.shared.setPluginEnabled(pluginId, newValue)
                // Re-advertise updated capabilities so peers see the change.
                LanLinkProvider.shared.refresh()
            }
        )
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { newValue in loginItem.setEnabled(newValue) }
        )
    }

    private var automaticUpdateBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { newValue in updater.automaticallyChecksForUpdates = newValue }
        )
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != settings.deviceName else { return }
        MacConnectCore.Settings.shared.deviceName = trimmed
        nameDraft = settings.deviceName
        LanLinkProvider.shared.refresh()
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func labelValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.caption, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
