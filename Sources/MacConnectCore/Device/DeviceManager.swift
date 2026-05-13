import Foundation
import Combine

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
            if device.outgoingPairRequest {
                // Peer accepted our request
                Settings.shared.markTrusted(device.id)
                device.isPaired = true
                device.outgoingPairRequest = false
            } else {
                // Peer is requesting we pair
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
}
