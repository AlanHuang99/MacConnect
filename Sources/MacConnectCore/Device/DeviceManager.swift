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
        objectWillChange.send()
    }

    public func acceptPairing(_ device: Device) {
        Settings.shared.markTrusted(device.id)
        device.isPaired = true
        device.pairRequestPending = false
        device.send(PairPacketBuilder.response(accept: true))
        objectWillChange.send()
    }

    public func rejectPairing(_ device: Device) {
        device.pairRequestPending = false
        device.send(PairPacketBuilder.response(accept: false))
        objectWillChange.send()
    }

    public func unpair(_ device: Device) {
        Settings.shared.unmarkTrusted(device.id)
        device.isPaired = false
        device.send(PairPacketBuilder.response(accept: false))
        objectWillChange.send()
    }

    public func requestPair(_ device: Device) {
        device.send(PairPacketBuilder.request())
    }
}
