import SwiftUI
import MacConnectCore

struct SettingsView: View {
    @Binding var isPresented: Bool
    @ObservedObject var settings: MacConnectCore.Settings = .shared
    @State private var nameDraft: String = MacConnectCore.Settings.shared.deviceName
    @State private var loginItemError: String?

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
                Text("Settings").font(.headline)
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
                                    .disabled(nameDraft == settings.deviceName || nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            Text("Shown to other devices when broadcasting. Max 32 chars; no \" ' , ; : . ! ? ( ) [ ] < >")
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
                        Toggle("Launch at login", isOn: loginItemBinding)
                        if let err = loginItemError {
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
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func trustedDeviceRow(id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(id).font(.system(.caption, design: .monospaced))
                Spacer()
                Button("Forget") {
                    MacConnectCore.Settings.shared.unmarkTrusted(id)
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
        }
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
            get: { LoginItem.isEnabled },
            set: { newValue in
                do {
                    try LoginItem.setEnabled(newValue)
                    loginItemError = nil
                } catch {
                    loginItemError = "Couldn't \(newValue ? "enable" : "disable") launch at login: \(error.localizedDescription)"
                }
            }
        )
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != settings.deviceName else { return }
        MacConnectCore.Settings.shared.deviceName = trimmed
        nameDraft = settings.deviceName
        LanLinkProvider.shared.refresh()
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
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
