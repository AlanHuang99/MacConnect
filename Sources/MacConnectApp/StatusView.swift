import SwiftUI
import MacConnectCore

struct StatusView: View {
    @ObservedObject var manager = DeviceManager.shared
    @ObservedObject var settings = MacConnectCore.Settings.shared
    @State private var showingSettings = false

    var body: some View {
        ZStack {
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
            .opacity(showingSettings ? 0 : 1)

            if showingSettings {
                SettingsView(isPresented: $showingSettings)
                    .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .frame(width: 360, height: 500)
        .animation(.easeInOut(duration: 0.15), value: showingSettings)
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

            if device.incomingPairRequest {
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

    private var pairedActions: some View {
        HStack(spacing: 6) {
            Button("Ping") { PingPlugin.send(to: device) }
            Button("Push Clipboard") { ClipboardPlugin.pushClipboard(to: device) }
            Button("Find") { FindMyPhonePlugin.ring(device) }
            Spacer()
            Button("Unpair") { DeviceManager.shared.unpair(device) }
                .foregroundStyle(.red)
        }
        .controlSize(.small)
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
