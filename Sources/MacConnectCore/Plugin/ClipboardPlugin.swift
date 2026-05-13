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
        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
            device.send(NetworkPacket(
                type: PacketType.clipboard,
                body: ["content": .string(s)]
            ))
            return
        }
        // No text — try an image. KDE Connect's protocol doesn't carry
        // binary clipboard data inline, so we send it as a `clipboard.png`
        // file payload over the same share channel files use. The peer
        // receives it as a file in Downloads; this is the same affordance
        // KDE Connect Linux uses for non-text pasteboard content.
        if let image = NSImage(pasteboard: NSPasteboard.general) {
            sendClipboardImage(image, to: device)
            return
        }
        Log.plugin.notice("Clipboard empty / unsupported; nothing to push")
    }

    @MainActor
    private static func sendClipboardImage(_ image: NSImage, to device: Device) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Log.plugin.error("Could not encode clipboard image as PNG")
            return
        }
        // Write to a process-unique temp file so concurrent pushes don't
        // clobber each other. Caller's responsibility to keep the file
        // around long enough for SharePlugin to read it; PayloadSender
        // does its own retain.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macconnect-clipboard-\(UUID().uuidString).png")
        do {
            try pngData.write(to: tmpURL)
        } catch {
            Log.plugin.error("Could not write clipboard image to temp: \(error.localizedDescription, privacy: .public)")
            return
        }
        Log.plugin.info("Pushing clipboard image (\(pngData.count, privacy: .public) bytes) to \(device.id, privacy: .public)")
        SharePlugin.sendFile(tmpURL, to: device)
    }
}

public final class ClipboardInbox: @unchecked Sendable {
    public static let shared = ClipboardInbox()
    public var received: [String: String] = [:]
}
