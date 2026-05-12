import SwiftUI
import UniformTypeIdentifiers
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
        .onAppear(perform: requestNowPlayingFromPeers)
    }

    /// Ask paired-and-online peers to push their current MPRIS state so the
    /// tile isn't blank on first popover open. Peers push subsequent updates
    /// proactively on track / state change.
    private func requestNowPlayingFromPeers() {
        for device in manager.deviceList() where device.isPaired && device.isReachable {
            MprisPlugin.requestNowPlaying(from: device)
        }
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
            .help("Re-broadcast & re-discover (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
            .keyboardShortcut(",", modifiers: .command)
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
            VStack(alignment: .leading, spacing: 4) {
                checklistItem("KDE Connect is running on the other device")
                checklistItem("Both devices are on the same Wi-Fi network")
                checklistItem("Local-network access allowed for MacConnect")
                checklistItem("Wi-Fi router isn't blocking peer-to-peer (AP isolation off)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func checklistItem(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.caption2)
            Text(text)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Text("This device: \(settings.deviceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(8)
    }
}

struct DeviceRow: View {
    @ObservedObject var device: Device
    @ObservedObject private var transfers = TransferStore.shared
    @ObservedObject private var mpris = MprisStore.shared
    @State private var isDropTarget: Bool = false

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

            if device.isPaired, device.isReachable, let mprisState = mpris.state(for: device.id) {
                mprisTile(mprisState)
            }

            ForEach(transfers.activeTransfers(forDeviceId: device.id)) { transfer in
                transferRow(transfer)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isDropTarget ? 4 : 0)
        .background(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        // Accept file drops only on devices we can actually send to.
        .onDrop(of: [.fileURL], isTargeted: device.isPaired && device.isReachable ? $isDropTarget : nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func mprisTile(_ state: MprisStore.State) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let line = state.titleLine {
                Text(line)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 4) {
                Text(state.player)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { MprisPlugin.previous(device) } label: {
                    Image(systemName: "backward.fill")
                }
                .disabled(!state.canGoPrevious)
                Button { MprisPlugin.playPause(device) } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { MprisPlugin.next(device) } label: {
                    Image(systemName: "forward.fill")
                }
                .disabled(!state.canGoNext)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func transferRow(_ transfer: TransferStore.Transfer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: transfer.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                    .font(.caption2)
                Text(transfer.filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(Self.formatTransferProgress(transfer))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: transfer.fractionComplete)
                .progressViewStyle(.linear)
        }
    }

    private static func formatTransferProgress(_ transfer: TransferStore.Transfer) -> String {
        let sent = formatBytes(transfer.transferredBytes)
        let total = formatBytes(transfer.totalBytes)
        return "\(sent) / \(total)"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard device.isPaired, device.isReachable else { return false }
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) else { return }
                Task { @MainActor in
                    SharePlugin.sendFile(url, to: device)
                }
            }
        }
        return accepted
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
        if device.isReachable {
            bits.append("online")
        } else if let age = lastSeenAge {
            bits.append("last seen \(age)")
        }
        return bits.joined(separator: " · ")
    }

    private var lastSeenAge: String? {
        guard !device.isReachable else { return nil }
        let secs = Int(Date().timeIntervalSince(device.lastSeen))
        if secs < 0 { return nil }
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }

    private var pairPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pair request from this device?")
                .font(.caption)
            if let fp = CertificateService.shared.fingerprint(forTrustedDeviceId: device.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verify this fingerprint matches the one shown on \(device.name):")
                        .font(.caption2).foregroundStyle(.secondary)
                    fingerprintRow(fp)
                }
            }
            HStack {
                Button("Accept") { DeviceManager.shared.acceptPairing(device) }
                Button("Reject") { DeviceManager.shared.rejectPairing(device) }
            }
        }
    }

    /// One-line, monospaced fingerprint with a Copy button so users can
    /// paste-compare against the other device's display.
    private func fingerprintRow(_ fingerprint: String, highlight: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(fingerprint)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(highlight ?? .primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fingerprint, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Copy fingerprint")
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
            fingerprintDiff
            HStack {
                Button("Reset Trust") { DeviceManager.shared.resetTrust(device) }
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var fingerprintDiff: some View {
        let pinned = CertificateService.shared.fingerprint(forTrustedDeviceId: device.id)
        let presented = device.presentedFingerprint
        if pinned != nil || presented != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let pinned {
                    Text("Pinned").font(.caption2).foregroundStyle(.secondary)
                    fingerprintRow(pinned)
                }
                if let presented {
                    Text("Presented").font(.caption2).foregroundStyle(.secondary)
                    fingerprintRow(presented, highlight: .orange)
                }
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
