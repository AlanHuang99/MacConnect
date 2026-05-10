import Foundation
import AppKit

/// Clipboard sync.
///
/// Outbound is manual: the user picks a paired device and clicks Push to
/// send the current pasteboard contents. There is no automatic broadcast
/// of every clipboard change to every paired device.
///
/// Inbound is applied to the Mac pasteboard immediately. The local
/// pasteboard is left untouched if the incoming content already matches it.
/// `kdeconnect.clipboard.connect` carries a timestamp; packets older than
/// 30 seconds are ignored so a reconnect does not clobber a fresher local
/// clipboard.
public final class ClipboardPlugin: Plugin, @unchecked Sendable {
    public let identifier = "clipboard"
    public let displayName = "Clipboard"
    public let incomingCapabilities = [PacketType.clipboard, PacketType.clipboardConnect]
    public let outgoingCapabilities = [PacketType.clipboard, PacketType.clipboardConnect]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        let name = device.name
        guard let content = packet.body["content"]?.stringValue else {
            Log.plugin.error("Clipboard packet missing 'content' field")
            return
        }

        // Skip stale .connect packets that are older than ~30s — these can
        // arrive on reconnect and would clobber a fresher local clipboard.
        if packet.type == PacketType.clipboardConnect,
           let ts = packet.body["timestamp"]?.intValue, ts > 0 {
            let packetTime = TimeInterval(ts) / 1000.0
            if Date().timeIntervalSince1970 - packetTime > 30 {
                Log.plugin.info("Ignoring stale clipboard.connect from \(name, privacy: .public) (\(packetTime, privacy: .public))")
                return
            }
        }

        // Don't re-apply if the local clipboard already has this content.
        let current = NSPasteboard.general.string(forType: .string)
        if current == content {
            Log.plugin.debug("Clipboard from \(name, privacy: .public) already matches local; skipping")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        ClipboardInbox.shared.received[device.id] = content
        Log.plugin.info("Applied clipboard from \(name, privacy: .public): \(content.count, privacy: .public) chars")
        await Notifier.show(
            title: "Clipboard from \(name)",
            body: String(content.prefix(80)) + (content.count > 80 ? "…" : "")
        )
    }

    @MainActor
    public static func pushClipboard(to device: Device) {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else {
            Log.plugin.notice("Clipboard empty; nothing to push")
            return
        }
        let packet = NetworkPacket(
            type: PacketType.clipboard,
            body: ["content": .string(s)]
        )
        device.send(packet)
    }
}

public final class ClipboardInbox: @unchecked Sendable {
    public static let shared = ClipboardInbox()
    public var received: [String: String] = [:]
}
