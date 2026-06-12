import Combine
import Foundation

@MainActor
public final class DeviceManager: ObservableObject {
    public static let shared = DeviceManager()

    @Published public private(set) var devices: [String: Device] = [:]

    public init() {}

    public func deviceList() -> [Device] {
        devices.values.sorted { $0.name < $1.name }
    }

    @discardableResult
    public func upsert(identity: IdentityPayload) -> Device {
        if let existing = devices[identity.deviceId] {
            existing.update(from: identity)
            return existing
        }
        let isPaired = Settings.shared.isTrusted(identity.deviceId)
        let device = Device(identity: identity, paired: isPaired)
        devices[identity.deviceId] = device
        objectWillChange.send()
        return device
    }

    public func attach(link: LanLink, to deviceId: String) {
        guard let device = devices[deviceId] else { return }
        device.link = link
        device.isReachable = true
        objectWillChange.send()
    }

    public func detach(deviceId: String) {
        guard let device = devices[deviceId] else { return }
        device.link = nil
        device.isReachable = false
        // Clear cached now-playing state so a stale title doesn't keep
        // showing when the peer reconnects but hasn't pushed a fresh
        // MPRIS packet yet. Cleared here rather than in unpair only —
        // every disconnect should invalidate the now-playing cache,
        // not just an explicit unpair.
        MprisStore.shared.clear(deviceId: deviceId)
        // Battery is level-triggered (a value stays valid until the next
        // packet), so a disconnect must invalidate it too — otherwise a
        // reconnecting peer briefly shows the previous charge. Mirrors the
        // MPRIS clear above; previously battery alone leaked across links.
        BatteryStore.shared.clear(deviceId: deviceId)
        objectWillChange.send()
    }

    public func acceptPairing(_ device: Device) {
        Settings.shared.markTrusted(device.id)
        device.isPaired = true
        device.incomingPairRequest = false
        device.outgoingPairRequest = false
        device.send(PairPacketBuilder.response(accept: true))
        objectWillChange.send()
    }

    public func rejectPairing(_ device: Device) {
        device.incomingPairRequest = false
        device.send(PairPacketBuilder.response(accept: false))
        objectWillChange.send()
    }

    public func unpair(_ device: Device) {
        Settings.shared.unmarkTrusted(device.id)
        Settings.shared.clearPerDevicePluginOverrides(forDevice: device.id)
        CertificateService.shared.deleteRemoteCert(deviceId: device.id)
        device.isPaired = false
        device.pinMismatch = false
        device.presentedFingerprint = nil
        MprisStore.shared.clear(deviceId: device.id)
        device.send(PairPacketBuilder.response(accept: false))
        objectWillChange.send()
    }

    /// Called from the TLS verifier when a paired peer presents a cert that
    /// no longer matches our stored pin. We surface this in the UI so the
    /// user can choose to reset trust (cleanly re-TOFU) rather than the link
    /// silently failing forever. `presentedFingerprint` is the colon-grouped
    /// SHA-256 of the cert the peer just offered — shown alongside the old
    /// pin so the user can compare visually.
    public func flagPinMismatch(deviceId: String, presentedFingerprint: String?) {
        guard let device = devices[deviceId] else { return }
        device.pinMismatch = true
        device.presentedFingerprint = presentedFingerprint
        objectWillChange.send()
    }

    /// Drop the pin and trust for this peer without sending a pair-cancel
    /// packet (the link is already dead at the TLS layer when this is
    /// invoked). Next discovery cycle the peer is treated as new and TOFU
    /// re-runs against its current cert.
    public func resetTrust(_ device: Device) {
        Settings.shared.unmarkTrusted(device.id)
        Settings.shared.clearPerDevicePluginOverrides(forDevice: device.id)
        CertificateService.shared.deleteRemoteCert(deviceId: device.id)
        device.isPaired = false
        device.pinMismatch = false
        device.presentedFingerprint = nil
        objectWillChange.send()
    }

    public func requestPair(_ device: Device) {
        device.outgoingPairRequest = true
        device.send(PairPacketBuilder.request())
        objectWillChange.send()
    }

    /// Called by the link layer when a pair packet arrives.
    public func didReceivePairPacket(accept: Bool, device: Device) {
        if accept {
            // Idempotency guard. KDE Connect peers (notably the iOS
            // app, and Android peers when a TLS handshake keeps cycling)
            // resend pair=true while already trusted. Without this guard
            // we'd flip incomingPairRequest=true again and re-prompt the
            // user with "Accept?" indefinitely — the pairing-loop bug.
            if device.isPaired {
                Log.pair
                    .debug("Already paired with \(device.id, privacy: .public); ignoring pair=true")
                // Re-confirm so the peer's state catches up if it
                // forgot the trust on its side. Cheap and idempotent.
                device.send(PairPacketBuilder.response(accept: true))
                device.incomingPairRequest = false
                device.outgoingPairRequest = false
                objectWillChange.send()
                return
            }
            if device.outgoingPairRequest {
                // Peer accepted our request.
                Settings.shared.markTrusted(device.id)
                device.isPaired = true
                device.outgoingPairRequest = false
            } else {
                // Peer is requesting we pair.
                device.incomingPairRequest = true
            }
        } else {
            // Unpair / rejection — clear all trust state including per-device
            // plugin overrides so a future re-pair starts clean.
            Settings.shared.unmarkTrusted(device.id)
            Settings.shared.clearPerDevicePluginOverrides(forDevice: device.id)
            CertificateService.shared.deleteRemoteCert(deviceId: device.id)
            device.isPaired = false
            device.outgoingPairRequest = false
            device.incomingPairRequest = false
        }
        objectWillChange.send()
    }

    // MARK: - Liveness reconciliation

    //
    // The old model derived "online" purely from link events: attach on TLS
    // secure, detach on socket close. When a close event never arrives — and
    // display sleep, screen saver, and phone Doze fire no socket-close, no
    // NSWorkspace wake, no NWPathMonitor change, and freeze NIO's read-idle
    // timer — a device stayed "online" with hours-old battery / now-playing
    // forever. This periodic pass re-derives reachability from freshness using
    // the wall clock (Date), which keeps counting across sleep, so it
    // self-corrects without depending on any event firing. `lastSeen` is
    // already stamped on every inbound packet via `upsert`, and a peer's reply
    // to our silent probe refreshes it — so a live link stays fresh and a dead
    // one ages out.

    /// How often the reconciler runs.
    public static let reconcileInterval: TimeInterval = 10
    /// A reachable, paired peer silent this long — despite us probing it — is
    /// treated as gone and its link dropped so discovery re-establishes it.
    public static let livenessTTL: TimeInterval = 60
    /// A reachable, paired peer quiet at least this long gets a silent probe
    /// (battery / mpris request — answered by the peer but never surfaced as a
    /// notification). Chatty links stay above this threshold on their own.
    public static let probeQuietThreshold: TimeInterval = 15
    /// An unpaired, offline discovery ghost older than this is dropped from the
    /// list. Paired peers are always kept so "last seen" stays visible.
    public static let unpairedEvictionAge: TimeInterval = 180

    private var reconcileTimer: Timer?

    /// Start the periodic liveness pass. Idempotent; wired from app launch.
    public func startReconciliation() {
        guard reconcileTimer == nil else { return }
        let timer = Timer(timeInterval: Self.reconcileInterval, repeats: true) { [weak self] _ in
            // Re-bind the weak `self` to a let before the inner Task captures
            // it: strict concurrency rejects an inner concurrent closure
            // reading the captured `self` var directly. Same dance as
            // LanLinkProvider's onPacket handler.
            let manager = self
            Task { @MainActor in manager?.reconcile() }
        }
        // `.common` so the pass keeps firing while the popover tracks a menu /
        // modal run-loop mode, not only in default mode.
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }

    /// Stop the liveness pass. Called on app termination.
    public func stopReconciliation() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
    }

    /// One reconciliation pass. `now` is injectable for tests.
    func reconcile(now: Date = Date()) {
        var evictIds: [String] = []
        for device in devices.values {
            let age = now.timeIntervalSince(device.lastSeen)
            if Self.shouldEvictUnpaired(
                isPaired: device.isPaired, isReachable: device.isReachable,
                age: age, maxAge: Self.unpairedEvictionAge
            ) {
                evictIds.append(device.id)
                continue
            }
            guard device.isReachable, device.isPaired else { continue }
            switch Self.livenessAction(
                age: age, probeable: Self.isProbeable(deviceId: device.id),
                ttl: Self.livenessTTL, quiet: Self.probeQuietThreshold
            ) {
            case .keep:
                break
            case .probe:
                sendLivenessProbe(to: device)
            case .drop:
                Log.net
                    .notice(
                        "Liveness TTL exceeded for \(device.id, privacy: .public) (\(Int(age), privacy: .public)s silent); marking offline"
                    )
                markGone(device)
            }
        }
        for id in evictIds {
            devices.removeValue(forKey: id)
            BatteryStore.shared.clear(deviceId: id)
            MprisStore.shared.clear(deviceId: id)
        }
        // Tick so "last seen Nm ago" advances even when nothing else changed.
        objectWillChange.send()
    }

    /// Drive a probably-dead peer offline now and drop its link so discovery
    /// redials it. The drop cascades back through `detach` (idempotent with the
    /// synchronous changes here); doing both gives instant UI feedback while
    /// guaranteeing the stale link is actually torn down so a reconnect isn't
    /// blocked by the `existing.isSecure` guard in discovery.
    private func markGone(_ device: Device) {
        device.isReachable = false
        device.link = nil
        BatteryStore.shared.clear(deviceId: device.id)
        MprisStore.shared.clear(deviceId: device.id)
        LanLinkProvider.shared.dropLink(deviceId: device.id)
    }

    /// Silent liveness probe: ask for battery / now-playing, honouring the
    /// per-device plugin toggles so we never contradict a muted plugin. The
    /// peer's reply flows back through `dispatch`, refreshing `lastSeen` and
    /// proving the link is alive. These are the same request packets the
    /// popover sends on open — peers answer them without raising a banner,
    /// which is why this works where the reverted `_keepalive` ping did not.
    private func sendLivenessProbe(to device: Device) {
        let id = device.id
        if Settings.shared.isPluginEnabled("battery", forDevice: id) {
            BatteryPlugin.requestUpdate(from: device)
        }
        if Settings.shared.isPluginEnabled("mpris", forDevice: id) {
            MprisPlugin.requestNowPlaying(from: device)
        }
    }

    enum LivenessAction: Equatable {
        case keep
        case probe
        case drop
    }

    /// Pure liveness decision for a reachable, paired peer — no timers, links,
    /// or singletons — so it's unit-testable. A peer we cannot probe (all probe
    /// plugins disabled) is never dropped on silence alone: we can't tell dead
    /// from idle, so we defer to the link-level mechanisms (no regression).
    nonisolated static func livenessAction(
        age: TimeInterval, probeable: Bool, ttl: TimeInterval, quiet: TimeInterval
    ) -> LivenessAction {
        if age > ttl { return probeable ? .drop : .keep }
        if probeable, age > quiet { return .probe }
        return .keep
    }

    /// Pure eviction predicate: only unpaired peers that are already offline
    /// and stale get removed. Paired peers and currently-reachable peers stay.
    nonisolated static func shouldEvictUnpaired(
        isPaired: Bool, isReachable: Bool, age: TimeInterval, maxAge: TimeInterval
    ) -> Bool {
        !isPaired && !isReachable && age > maxAge
    }

    nonisolated static func isProbeable(deviceId: String) -> Bool {
        Settings.shared.isPluginEnabled("battery", forDevice: deviceId)
            || Settings.shared.isPluginEnabled("mpris", forDevice: deviceId)
    }
}
