import Foundation
import Combine

/// Observable record of in-flight and recently-completed file transfers.
/// `SharePlugin` pushes lifecycle events here; the UI reads.
///
/// The `recent` list persists across launches (last 20) so the user can
/// see what they sent / received last session. The active list does not.
@MainActor
public final class TransferStore: ObservableObject {
    public static let shared = TransferStore()

    public enum Direction: String, Codable, Sendable {
        case outgoing, incoming
    }

    public enum State: Equatable, Sendable {
        case inProgress
        case completed
        case failed(String)
    }

    public struct Transfer: Identifiable, Sendable {
        public let id: UUID
        public let deviceId: String
        public let deviceName: String
        public let filename: String
        public let direction: Direction
        public let totalBytes: Int64
        public var transferredBytes: Int64
        public var state: State
        public let startedAt: Date
        public var endedAt: Date?

        public var fractionComplete: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1.0, Double(transferredBytes) / Double(totalBytes))
        }
    }

    @Published public private(set) var active: [Transfer] = []
    @Published public private(set) var recent: [Transfer] = []

    /// Most recent 20 completed (success or failure) transfers, kept in
    /// memory and persisted to UserDefaults so the Recent Transfers list
    /// survives an app restart.
    public static let recentLimit = 20

    private let userDefaultsKey = "macconnect.recentTransfers"

    public init() {
        recent = Self.loadRecent(forKey: userDefaultsKey)
    }

    public func begin(
        deviceId: String,
        deviceName: String,
        filename: String,
        direction: Direction,
        totalBytes: Int64
    ) -> UUID {
        let id = UUID()
        let t = Transfer(
            id: id,
            deviceId: deviceId,
            deviceName: deviceName,
            filename: filename,
            direction: direction,
            totalBytes: totalBytes,
            transferredBytes: 0,
            state: .inProgress,
            startedAt: Date(),
            endedAt: nil
        )
        active.append(t)
        return id
    }

    public func updateProgress(id: UUID, transferred: Int64) {
        guard let idx = active.firstIndex(where: { $0.id == id }) else { return }
        active[idx].transferredBytes = transferred
    }

    public func complete(id: UUID, success: Bool, error: String? = nil) {
        guard let idx = active.firstIndex(where: { $0.id == id }) else { return }
        var t = active.remove(at: idx)
        t.state = success ? .completed : .failed(error ?? "Unknown error")
        t.endedAt = Date()
        if success {
            t.transferredBytes = t.totalBytes
        }
        recent.insert(t, at: 0)
        if recent.count > Self.recentLimit {
            recent.removeLast(recent.count - Self.recentLimit)
        }
        persistRecent()
    }

    /// Active transfers for a specific device — UI binds against this for
    /// inline progress bars in DeviceRow.
    public func activeTransfers(forDeviceId deviceId: String) -> [Transfer] {
        active.filter { $0.deviceId == deviceId }
    }

    private func persistRecent() {
        let payload = recent.map(PersistedTransfer.init(from:))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    private static func loadRecent(forKey key: String) -> [Transfer] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let payload = try? JSONDecoder().decode([PersistedTransfer].self, from: data) else {
            return []
        }
        return payload.map(\.toTransfer)
    }
}

/// JSON-codable mirror of `Transfer`; `Transfer.State` carries an
/// associated value so we lift it to discrete fields here.
private struct PersistedTransfer: Codable {
    let id: UUID
    let deviceId: String
    let deviceName: String
    let filename: String
    let direction: TransferStore.Direction
    let totalBytes: Int64
    let transferredBytes: Int64
    let stateKind: String      // "completed" / "failed"
    let errorMessage: String?
    let startedAt: Date
    let endedAt: Date?

    init(from t: TransferStore.Transfer) {
        self.id = t.id
        self.deviceId = t.deviceId
        self.deviceName = t.deviceName
        self.filename = t.filename
        self.direction = t.direction
        self.totalBytes = t.totalBytes
        self.transferredBytes = t.transferredBytes
        self.startedAt = t.startedAt
        self.endedAt = t.endedAt
        switch t.state {
        case .inProgress:
            // Active transfers shouldn't reach disk, but if they do we
            // best-effort downgrade them to "failed" so the user sees a
            // recognisable terminal state on next launch.
            self.stateKind = "failed"
            self.errorMessage = "Interrupted"
        case .completed:
            self.stateKind = "completed"
            self.errorMessage = nil
        case .failed(let msg):
            self.stateKind = "failed"
            self.errorMessage = msg
        }
    }

    var toTransfer: TransferStore.Transfer {
        let state: TransferStore.State
        switch stateKind {
        case "completed": state = .completed
        case "failed":    state = .failed(errorMessage ?? "Unknown error")
        default:          state = .failed("Unknown state")
        }
        return .init(
            id: id,
            deviceId: deviceId,
            deviceName: deviceName,
            filename: filename,
            direction: direction,
            totalBytes: totalBytes,
            transferredBytes: transferredBytes,
            state: state,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }
}
