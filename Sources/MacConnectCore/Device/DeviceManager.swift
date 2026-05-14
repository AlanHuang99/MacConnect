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
        objectWillChange.send()
    }

    public func acceptPairing(_ device: Device) {
        guard device.send(PairPacketBuilder.response(accept: true)) else {
            Log.pair.notice("Pair accept not sent to \(device.id, privacy: .public)")
            DiagnosticLog.shared.record("pair", "accept-send-failed device=\(device.id)")
            TransferStore.shared.publishCommandFailure(
                message: "Pairing failed",
                detail: "Device not ready"
            )
            objectWillChange.send()
            return
        }
        Settings.shared.markTrusted(device.id)
        device.isPaired = true
        device.incomingPairRequest = false
        device.outgoingPairRequest = false
        DiagnosticLog.shared.record("pair", "accept-sent device=\(device.id)")
        objectWillChange.send()
    }

    public func rejectPairing(_ device: Device) {
        device.incomingPairRequest = false
        if !device.send(PairPacketBuilder.response(accept: false)) {
            Log.pair.notice("Pair reject not sent to \(device.id, privacy: .public)")
            DiagnosticLog.shared.record("pair", "reject-send-failed device=\(device.id)")
            TransferStore.shared.publishCommandFailure(
                message: "Pair response not sent",
                detail: "Device not ready"
            )
        } else {
            DiagnosticLog.shared.record("pair", "reject-sent device=\(device.id)")
        }
        objectWillChange.send()
    }

    public func unpair(_ device: Device) {
        let sent = device.send(PairPacketBuilder.response(accept: false))
        if !sent {
            Log.pair.notice("Unpair notice not sent to \(device.id, privacy: .public)")
            DiagnosticLog.shared.record("pair", "unpair-send-failed device=\(device.id)")
            TransferStore.shared.publishCommandFailure(
                message: "Unpaired locally",
                detail: "The peer could not be notified"
            )
        } else {
            DiagnosticLog.shared.record("pair", "unpair-sent device=\(device.id)")
        }
        Settings.shared.unmarkTrusted(device.id)
        Settings.shared.clearPerDevicePluginOverrides(forDevice: device.id)
        CertificateService.shared.deleteRemoteCert(deviceId: device.id)
        device.isPaired = false
        device.outgoingPairRequest = false
        device.incomingPairRequest = false
        device.pinMismatch = false
        device.presentedFingerprint = nil
        MprisStore.shared.clear(deviceId: device.id)
        LanLinkProvider.shared.disconnect(deviceId: device.id, reason: "local-unpair")
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
        guard device.send(PairPacketBuilder.request()) else {
            device.outgoingPairRequest = false
            Log.pair.notice("Pair request not sent to \(device.id, privacy: .public)")
            DiagnosticLog.shared.record("pair", "request-send-failed device=\(device.id)")
            TransferStore.shared.publishCommandFailure(
                message: "Pair request not sent",
                detail: "Device not ready"
            )
            objectWillChange.send()
            return
        }
        device.outgoingPairRequest = true
        DiagnosticLog.shared.record("pair", "request-sent device=\(device.id)")
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
                if !device.send(PairPacketBuilder.response(accept: true)) {
                    DiagnosticLog.shared.record("pair", "reconfirm-send-failed device=\(device.id)")
                }
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
            LanLinkProvider.shared.disconnect(deviceId: device.id, reason: "remote-pair-false")
            DiagnosticLog.shared.record("pair", "remote-false device=\(device.id)")
        }
        objectWillChange.send()
    }
}
