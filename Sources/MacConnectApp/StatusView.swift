import SwiftUI
import MacConnectCore

struct StatusView: View {
    @ObservedObject var manager = DeviceManager.shared
    @ObservedObject var settings = MacConnectCore.Settings.shared
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            if showingSettings {
                SettingsView(isPresented: $showingSettings)
                    .background(Color(NSColor.windowBackgroundColor))
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    if manager.deviceList().isEmpty {
                        empty
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(manager.deviceList()) { device in
                                    DeviceRow(device: device)
                                    Divider()
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    Divider()
                    footer
                }
                .transition(.opacity)
            }
        }
        .frame(width: 360, height: 500)
        .animation(.easeInOut(duration: 0.12), value: showingSettings)
    }

    private var header: some View {
        HStack {
            Image(systemName: "iphone.radiowaves.left.and.right")
            Text("MacConnect").font(.headline)
            Spacer()
            Button {
                LanLinkProvider.shared.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-broadcast & re-discover")
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Searching for devices…")
                .foregroundStyle(.secondary)
            Text("Make sure KDE Connect is running on your phone\nand both devices are on the same Wi-Fi.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("This device: \(settings.deviceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(8)
    }
}

struct DeviceRow: View {
    @ObservedObject var device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: deviceSymbol)
                VStack(alignment: .leading) {
                    Text(device.name).font(.body.weight(.medium))
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(device.isReachable ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            }

            if device.pinMismatch {
                pinMismatchPrompt
            } else if device.incomingPairRequest {
                pairPrompt
            } else if device.isPaired {
                pairedActions
            } else {
                unpairedActions
            }
        }
        .padding(.horizontal, 12)
    }

    private var deviceSymbol: String {
        switch device.type {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        case .desktop: return "desktopcomputer"
        case .tv: return "tv"
        }
    }

    private var statusLine: String {
        var bits: [String] = []
        bits.append(device.type.rawValue.capitalized)
        bits.append(device.isPaired ? "paired" : "not paired")
        if device.isReachable { bits.append("online") }
        return bits.joined(separator: " · ")
    }

    private var pairPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pair request from this device?")
                .font(.caption)
            HStack {
                Button("Accept") { DeviceManager.shared.acceptPairing(device) }
                Button("Reject") { DeviceManager.shared.rejectPairing(device) }
            }
        }
    }

    private var pinMismatchPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Certificate changed")
                        .font(.caption.weight(.semibold))
                    Text("This device's identity does not match the one we pinned. If you trust it (e.g. the app was reinstalled), reset trust and re-pair.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Reset Trust") { DeviceManager.shared.resetTrust(device) }
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    private var pairedActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button("Ping") { PingPlugin.send(to: device) }
                Button("Clipboard") { ClipboardPlugin.pushClipboard(to: device) }
                Button("Find") { FindMyPhonePlugin.ring(device) }
                Button("Send File…") { presentFilePicker() }
                Spacer()
                Button("Unpair") { DeviceManager.shared.unpair(device) }
                    .foregroundStyle(.red)
            }
        }
        .controlSize(.small)
    }

    private func presentFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Send file to \(device.name)"
        panel.prompt = "Send"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                SharePlugin.sendFile(url, to: device)
            }
        }
    }

    private var unpairedActions: some View {
        HStack {
            if device.outgoingPairRequest {
                ProgressView().controlSize(.small)
                Text("Waiting for peer to accept…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    device.outgoingPairRequest = false
                }
            } else {
                Button("Request Pair") { DeviceManager.shared.requestPair(device) }
                    .disabled(!device.isReachable)
                Spacer()
            }
        }
        .controlSize(.small)
    }
}
