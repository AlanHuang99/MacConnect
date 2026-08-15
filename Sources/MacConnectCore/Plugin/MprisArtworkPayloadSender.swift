import Foundation

struct MprisArtworkPayloadListener {
    let port: UInt16
    let cancel: @MainActor () -> Void
}

enum MprisArtworkPayloadOutcome {
    case success
    case failure
}

@MainActor
final class MprisArtworkPayloadSender {
    typealias StartPayload = @MainActor (
        _ fileURL: URL,
        _ peerDeviceId: String,
        _ onFinished: @escaping @Sendable (MprisArtworkPayloadOutcome) -> Void
    ) -> MprisArtworkPayloadListener
    typealias SendPacket = @MainActor (NetworkPacket, Device) -> Bool

    @MainActor
    private final class Cleanup {
        private let fileURL: URL
        private var didRun = false

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func run() {
            guard !didRun else { return }
            didRun = true
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private let temporaryDirectory: URL
    private let startPayload: StartPayload
    private let sendPacket: SendPacket

    convenience init() {
        self.init(
            temporaryDirectory: FileManager.default.temporaryDirectory,
            startPayload: Self.startLivePayload,
            sendPacket: { packet, device in device.send(packet) }
        )
    }

    init(
        temporaryDirectory: URL,
        startPayload: @escaping StartPayload,
        sendPacket: @escaping SendPacket
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.startPayload = startPayload
        self.sendPacket = sendPacket
    }

    func send(_ transfer: MprisArtworkTransfer, to device: Device) {
        guard !transfer.data.isEmpty,
              transfer.data.count <= LocalMprisService.maximumArtworkBytes
        else { return }

        let fileURL = temporaryDirectory.appendingPathComponent(
            "macconnect-album-art-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try transfer.data.write(to: fileURL, options: .atomic)
        } catch {
            Log.plugin.error("Could not prepare album art payload: \(error.localizedDescription, privacy: .public)")
            return
        }

        let cleanup = Cleanup(fileURL: fileURL)
        let listener = startPayload(fileURL, device.id) { _ in
            Task { @MainActor in cleanup.run() }
        }
        guard listener.port != 0 else {
            cleanup.run()
            return
        }

        var packet = NetworkPacket(
            type: PacketType.mpris,
            body: [
                "player": .string(transfer.player),
                "transferringAlbumArt": .bool(true),
                "albumArtUrl": .string(transfer.url)
            ]
        )
        packet.payloadSize = Int64(transfer.data.count)
        packet.payloadTransferInfo = ["port": .int(Int64(listener.port))]

        guard sendPacket(packet, device) else {
            cleanup.run()
            listener.cancel()
            return
        }
    }

    private static func startLivePayload(
        fileURL: URL,
        peerDeviceId: String,
        onFinished: @escaping @Sendable (MprisArtworkPayloadOutcome) -> Void
    ) -> MprisArtworkPayloadListener {
        let started = PayloadTransport.startSender(
            fileURL: fileURL,
            peerDeviceId: peerDeviceId,
            onComplete: {},
            onError: { error in
                Log.plugin.error("Album art payload failed: \(error.localizedDescription, privacy: .public)")
            }
        )
        started.completion.futureResult.whenComplete { result in
            switch result {
            case .success:
                onFinished(.success)
            case .failure:
                onFinished(.failure)
            }
        }
        return MprisArtworkPayloadListener(port: started.port) {
            started.completion.fail(NSError(
                domain: "MacConnect.MprisArtwork",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Album art control packet was not sent"]
            ))
        }
    }
}
