import MacConnectCore
import SwiftUI
import UniformTypeIdentifiers

struct StatusView: View {
    @ObservedObject var manager = DeviceManager.shared
    @ObservedObject var settings = MacConnectCore.Settings.shared
    @ObservedObject var transfers = TransferStore.shared
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
                    if let toast = transfers.toast {
                        toastBanner(toast)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Divider()
                    if manager.deviceList().isEmpty {
                        empty
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(sortedDevices) { device in
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
        .animation(.easeInOut(duration: 0.18), value: transfers.toast?.id)
        .animation(.easeInOut(duration: 0.12), value: showingSettings)
        .onAppear(perform: requestBatteryFromPeers)
    }

    /// Always-visible confirmation that a send/receive completed, even
    /// when the OS notification path is denied. Auto-clears via
    /// `TransferStore.toast`'s own timer; the user can also tap the X.
    private func toastBanner(_ toast: TransferStore.Toast) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.kind == .success ? .green : .orange)
                .font(.callout)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.message)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = toast.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                transfers.dismissToast()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            (toast.kind == .success ? Color.green : Color.orange)
                .opacity(0.10)
        )
    }

    /// Ask paired-and-online peers to push their current battery state so
    /// rows aren't blank on first popover open. The call is gated on the
    /// per-device + global plugin enable state.
    private func requestBatteryFromPeers() {
        for device in manager.deviceList() where device.isPaired && device.isReachable {
            let id = device.id
            if MacConnectCore.Settings.shared.isPluginEnabled("battery", forDevice: id) {
                BatteryPlugin.requestUpdate(from: device)
            }
        }
    }

    /// Paired devices first, then by name; gives the popover a stable
    /// "people you talk to" grouping above the discovery noise.
    private var sortedDevices: [Device] {
        manager.deviceList().sorted { lhs, rhs in
            if lhs.isPaired != rhs.isPaired { return lhs.isPaired }
            if lhs.isReachable != rhs.isReachable { return lhs.isReachable }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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
    @ObservedObject private var battery = BatteryStore.shared
    @State private var isDropTarget: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                deviceIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.body.weight(.medium))
                    Text(statusLine).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                trailingControls
            }

            if device.pinMismatch {
                pinMismatchPrompt
            } else if device.incomingPairRequest {
                pairPrompt
            } else if !device.isPaired {
                unpairedActions
            }

            ForEach(transfers.activeTransfers(forDeviceId: device.id)) { transfer in
                transferRow(transfer)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(rowBackground)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .onDrop(of: [.fileURL], isTargeted: device.isPaired && device.isReachable ? $isDropTarget : nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private var deviceIcon: some View {
        ZStack {
            Circle()
                .fill(.tint.opacity(0.15))
                .frame(width: 32, height: 32)
            Image(systemName: deviceSymbol)
                .font(.system(size: 16))
                .foregroundStyle(.tint)
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        if device.isPaired, device.isReachable, !device.pinMismatch, !device.incomingPairRequest {
            HStack(spacing: 4) {
                Button("Send") { presentFilePicker() }
                    .controlSize(.small)
                pairedOverflowMenu
            }
        } else {
            Circle()
                .fill(device.isReachable ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
        }
    }

    private var pairedOverflowMenu: some View {
        Menu {
            Button("Ping") { PingPlugin.send(to: device) }
            Button("Push Clipboard") { ClipboardPlugin.pushClipboard(to: device) }
            Divider()
            Button("Unpair", role: .destructive) { DeviceManager.shared.unpair(device) }
        } label: {
            // Plain `ellipsis` rather than `ellipsis.circle` — the system
            // Menu adds its own visual affordance (a subtle hover hit-area)
            // and the doubled circle outline crowded the adjacent Send
            // button on dense rows.
            Image(systemName: "ellipsis")
                .symbolVariant(.none)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .menuStyle(.borderlessButton)
        // Hide the default disclosure chevron — without this, SwiftUI
        // tucks a small ⌄ next to the label which looks like a stray glyph
        // against busy backgrounds and was the "red circle" the previous
        // build appeared to grow.
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isDropTarget {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.18))
        } else {
            Color.clear
        }
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
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            // URL conforms to NSItemProviderReading on macOS, which handles
            // both single-file drops and folder/archive payloads correctly.
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      !isDir.boolValue else { return }
                Task { @MainActor in
                    SharePlugin.sendFile(url, to: device)
                }
            }
        }
        return accepted
    }

    private var deviceSymbol: String {
        switch device.type {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        case .tv: "tv"
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
        // Battery is only meaningful when (a) we still trust the peer
        // (otherwise we'd be displaying cached data for an unpaired
        // device), (b) it's currently reachable (otherwise stale), and
        // (c) the battery plugin is actually enabled for this peer — the
        // user can disable it globally or per-device, in which case the
        // cache may exist from before the toggle and shouldn't be shown.
        let id = device.id
        if device.isPaired,
           device.isReachable,
           MacConnectCore.Settings.shared.isPluginEnabled("battery", forDevice: id),
           let bat = battery.state(for: id)
        {
            bits.append("\(bat.currentCharge)%\(bat.isCharging ? " ⚡" : "")")
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
                    Text(
                        "This device's identity does not match the one we pinned. If you trust it (e.g. the app was reinstalled), reset trust and re-pair."
                    )
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

    private func presentFilePicker() {
        // Hop off the SwiftUI button-action stack so the popover can finish
        // its own dismissal animation before the picker comes up.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowsOtherFileTypes = true
            panel.treatsFilePackagesAsDirectories = false
            panel.title = "Send file to \(device.name)"
            panel.prompt = "Send"
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { [device] result in
                guard result == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    SharePlugin.sendFile(url, to: device)
                }
            }
        }
    }
}
