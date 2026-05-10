import SwiftUI
import MacConnectCore

struct SettingsView: View {
    @Binding var isPresented: Bool
    @ObservedObject var settings: MacConnectCore.Settings = .shared
    @State private var nameDraft: String = MacConnectCore.Settings.shared.deviceName

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Settings").font(.headline)
                Spacer()
                Color.clear.frame(width: 60)
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
                    }

                    section("Trusted devices") {
                        let trusted = settings.trustedDeviceIds.sorted()
                        if trusted.isEmpty {
                            Text("No paired devices yet.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(trusted, id: \.self) { id in
                                HStack {
                                    Text(id).font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Button("Forget") {
                                        MacConnectCore.Settings.shared.unmarkTrusted(id)
                                        settings.objectWillChange.send()
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != settings.deviceName else { return }
        MacConnectCore.Settings.shared.deviceName = trimmed
        nameDraft = settings.deviceName
        // Re-broadcast immediately so peers see the new name
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
        }
    }
}
