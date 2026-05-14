import Foundation

/// Per-peer dial-failure tracker with exponential backoff.
///
/// `LanLinkProvider` consults this before dialing a peer it just saw on
/// the wire, and updates it on every connect/handshake outcome. The
/// goal is to prevent the redial-every-5s loop that happens when a
/// peer's TLS handshake keeps failing (e.g. an incompatible iOS build).
///
/// Designed to be small, value-typed, and testable in isolation —
/// `LanLinkProvider`'s lock owns synchronization.
struct DialCooldownTracker {
    /// Backoff window in seconds, indexed by failure count - 1. The
    /// last entry is the cap; failure 6 and beyond reuse the same wait.
    static let backoffSeconds: [TimeInterval] = [10, 30, 60, 120, 300]

    private struct Entry {
        var failures: Int
        var nextAllowed: Date
    }

    private var entries: [String: Entry] = [:]

    /// Whether a dial attempt is allowed right now. `now` is injectable
    /// so tests can advance the clock without sleeping.
    func canDial(deviceId: String, now: Date = Date()) -> Bool {
        guard let entry = entries[deviceId] else { return true }
        return entry.nextAllowed <= now
    }

    /// Record a failed connect/handshake attempt and advance the cooldown.
    mutating func recordFailure(deviceId: String, now: Date = Date()) {
        let prior = entries[deviceId]?.failures ?? 0
        let next = prior + 1
        let idx = min(next - 1, Self.backoffSeconds.count - 1)
        let waitSec = Self.backoffSeconds[idx]
        entries[deviceId] = Entry(
            failures: next,
            nextAllowed: now.addingTimeInterval(waitSec)
        )
    }

    /// Successful TLS handshake — reset the peer's failure counter.
    mutating func clear(deviceId: String) {
        entries.removeValue(forKey: deviceId)
    }

    /// Drop all state. Called on `LanLinkProvider.stop()`.
    mutating func removeAll() {
        entries.removeAll()
    }

    /// Test helper: how many consecutive failures have been recorded
    /// for this peer. Returns 0 if the peer is clean.
    func failureCount(deviceId: String) -> Int {
        entries[deviceId]?.failures ?? 0
    }
}
