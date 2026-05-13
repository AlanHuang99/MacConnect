import Foundation
import AppKit

public final class SharePlugin: Plugin, @unchecked Sendable {
    public let identifier = "share"
    public let displayName = "Share"
    public let incomingCapabilities = [PacketType.shareRequest]
    public let outgoingCapabilities = [PacketType.shareRequest]

    public init() {}

    @MainActor
    public func handle(packet: NetworkPacket, from device: Device) async {
        // URL share
        if let url = packet.body["url"]?.stringValue {
            let name = device.name
            Log.plugin.info("Share URL from \(name, privacy: .public): \(url, privacy: .public)")
            await Notifier.show(title: "URL from \(name)", body: url)
            return
        }

        // Text share
        if let text = packet.body["text"]?.stringValue {
            let name = device.name
            Log.plugin.info("Share text from \(name, privacy: .public)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            await Notifier.show(title: "Text from \(name) (copied)",
                                body: String(text.prefix(80)))
            return
        }

        // File payload share
        guard let filename = packet.body["filename"]?.stringValue,
              let payloadSize = packet.payloadSize,
              let info = packet.payloadTransferInfo,
              let port = info["port"]?.intValue else {
            Log.plugin.notice("Share request without payload info; ignoring")
            return
        }

        guard let host = SharePlugin.peerHost(for: device) else {
            Log.plugin.error("Cannot determine peer host for \(device.id, privacy: .public); skipping file receive")
            return
        }

        let safeName = SharePlugin.sanitizeFilename(filename)
        let downloads = (try? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let target = SharePlugin.uniqueDestination(in: downloads, named: safeName)

        Log.plugin.info("Receiving file '\(safeName, privacy: .public)' (\(payloadSize, privacy: .public) bytes) from \(device.name, privacy: .public) via port \(port, privacy: .public)")

        let deviceName = device.name
        let deviceId = device.id
        let transferId = TransferStore.shared.begin(
            deviceId: deviceId,
            deviceName: deviceName,
            filename: safeName,
            direction: .incoming,
            totalBytes: payloadSize
        )
        PayloadTransport.startReceiver(
            host: host,
            port: UInt16(port),
            fileURL: target,
            expectedSize: payloadSize,
            peerDeviceId: device.id,
            onProgress: { bytes in
                Task { @MainActor in
                    TransferStore.shared.updateProgress(id: transferId, transferred: bytes)
                }
            },
            onComplete: {
                Task { @MainActor in
                    TransferStore.shared.complete(id: transferId, success: true)
                    await Notifier.show(title: "File from \(deviceName)", body: target.lastPathComponent)
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                }
            },
            onError: { err in
                Task { @MainActor in
                    TransferStore.shared.complete(id: transferId, success: false, error: err.localizedDescription)
                    await Notifier.show(title: "File transfer failed",
                                        body: "\(safeName): \(err.localizedDescription)")
                }
            }
        )
    }

    @MainActor
    public static func sendFile(_ url: URL, to device: Device) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let lastModified = ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970).map { Int64($0 * 1000) } ?? 0

        let deviceName = device.name
        let deviceId = device.id
        let filename = url.lastPathComponent
        let transferId = TransferStore.shared.begin(
            deviceId: deviceId,
            deviceName: deviceName,
            filename: filename,
            direction: .outgoing,
            totalBytes: size
        )
        let (port, finished) = PayloadTransport.startSender(
            fileURL: url,
            peerDeviceId: device.id,
            onProgress: { bytes in
                Task { @MainActor in
                    TransferStore.shared.updateProgress(id: transferId, transferred: bytes)
                }
            },
            onComplete: {
                Log.plugin.info("Sent \(filename, privacy: .public) to \(deviceName, privacy: .public)")
                Task { @MainActor in
                    TransferStore.shared.complete(id: transferId, success: true)
                    await Notifier.show(title: "Sent to \(deviceName)", body: filename)
                }
            },
            onError: { err in
                Log.plugin.error("Send failed: \(err.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    TransferStore.shared.complete(id: transferId, success: false, error: err.localizedDescription)
                    await Notifier.show(title: "Send failed", body: "\(filename): \(err.localizedDescription)")
                }
            }
        )
        // Receiver-never-connected timeout fails `finished` directly without
        // firing the handler's onError, which would otherwise be the only
        // path to TransferStore.complete. Observe the future so the UI never
        // gets stuck on an in-flight transfer that already died upstream.
        finished.whenFailure { err in
            Task { @MainActor in
                guard TransferStore.shared.active.contains(where: { $0.id == transferId }) else { return }
                TransferStore.shared.complete(id: transferId, success: false, error: err.localizedDescription)
                await Notifier.show(title: "Send failed", body: "\(filename): \(err.localizedDescription)")
            }
        }
        guard port != 0 else {
            // Listener bind failed — TransferStore already marked failed via onError above.
            return
        }

        let body: [String: AnyJSON] = [
            "filename": .string(filename),
            "lastModified": .int(lastModified),
            "numberOfFiles": .int(1),
            "totalPayloadSize": .int(size),
        ]
        var packet = NetworkPacket(type: PacketType.shareRequest, body: body)
        packet.payloadSize = size
        packet.payloadTransferInfo = ["port": .int(Int64(port))]
        device.send(packet)
    }

    // MARK: - Helpers

    static func peerHost(for device: Device) -> String? {
        // Pull the active channel's remote address from LanLinkProvider.
        return LanLinkProvider.shared.peerHost(for: device.id)
    }

    static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        return cleaned.isEmpty ? "file" : cleaned
    }

    static func uniqueDestination(in directory: URL, named name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 1
        while true {
            let suffix = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = directory.appendingPathComponent(suffix)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            i += 1
        }
    }
}
