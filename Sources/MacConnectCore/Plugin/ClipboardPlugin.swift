import Foundation
import AppKit

/// Manual-only clipboard. Auto-sync is intentionally NOT implemented because
/// it caused the original Soduto frustration of bouncing clipboard between
/// every paired device.
public final class ClipboardPlugin: Plugin, @unchecked Sendable {
    public let identifier = "clipboard"
    public let displayName = "Clipboard"
    public let incomingCapabilities = [PacketType.clipboard, PacketType.clipboardConnect]
    public let outgoingCapabilities = [PacketType.clipboard]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        guard let content = packet.body["content"]?.stringValue else { return }
        let name = device.name
        Log.plugin.info("Clipboard packet from \(name, privacy: .public) (manual review)")
        await Notifier.showAction(
            title: "Clipboard from \(name)",
            body: String(content.prefix(80)) + (content.count > 80 ? "…" : ""),
            actions: ["Copy", "Ignore"]
        )
        ClipboardInbox.shared.received[device.id] = content
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

    @MainActor
    public static func acceptIncoming(for device: Device) {
        guard let s = ClipboardInbox.shared.received[device.id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

public final class ClipboardInbox: @unchecked Sendable {
    public static let shared = ClipboardInbox()
    public var received: [String: String] = [:]
}
