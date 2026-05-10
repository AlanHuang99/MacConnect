import Foundation
import Network

public final class LanLink: @unchecked Sendable {
    public let deviceId: String
    public var isSecure: Bool = false

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var receiveBuffer = Data()
    private let onPacket: @Sendable (NetworkPacket) -> Void
    private let onClose: @Sendable () -> Void

    public init(
        deviceId: String,
        connection: NWConnection,
        onPacket: @escaping @Sendable (NetworkPacket) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.deviceId = deviceId
        self.connection = connection
        self.queue = DispatchQueue(label: "macconnect.link.\(deviceId)")
        self.onPacket = onPacket
        self.onClose = onClose
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.net.info("Link ready: \(self.deviceId, privacy: .public)")
                self.scheduleReceive()
            case .failed(let err):
                Log.net.error("Link failed \(self.deviceId, privacy: .public): \(err.localizedDescription, privacy: .public)")
                self.onClose()
            case .cancelled:
                self.onClose()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func disconnect() {
        connection.cancel()
    }

    public func send(_ packet: NetworkPacket) {
        do {
            let data = try packet.serialized()
            connection.send(content: data, completion: .contentProcessed { err in
                if let err {
                    Log.net.error("Send failed for \(packet.type, privacy: .public): \(err.localizedDescription, privacy: .public)")
                }
            })
        } catch {
            Log.net.error("Serialize failed for \(packet.type, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleReceive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainPackets()
            }
            if let error {
                Log.net.error("Receive failed: \(error.localizedDescription, privacy: .public)")
                self.onClose()
                return
            }
            if isComplete {
                self.onClose()
                return
            }
            self.scheduleReceive()
        }
    }

    private func drainPackets() {
        while let lf = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer.subdata(in: receiveBuffer.startIndex..<lf)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...lf)
            guard !line.isEmpty else { continue }
            do {
                let packet = try NetworkPacket.parse(line)
                onPacket(packet)
            } catch {
                Log.net.error("Bad packet: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
