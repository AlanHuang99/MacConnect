import Foundation
import IOKit

public final class Settings: @unchecked Sendable {
    public static let shared = Settings()

    private let defaults = UserDefaults.standard
    private let ud_deviceId = "macconnect.deviceId"
    private let ud_deviceName = "macconnect.deviceName"
    private let ud_trustedDevices = "macconnect.trustedDevices"

    public static let protocolVersion = 7
    public static let udpPort: UInt16 = 1716
    public static let minTCPPort: UInt16 = 1716
    public static let maxTCPPort: UInt16 = 1764

    public var deviceId: String {
        if let v = defaults.string(forKey: ud_deviceId) { return v }
        let v = (Self.platformUUID() ?? UUID().uuidString).replacingOccurrences(of: "-", with: "_")
        defaults.set(v, forKey: ud_deviceId)
        return v
    }

    public var deviceName: String {
        get { defaults.string(forKey: ud_deviceName) ?? Host.current().localizedName ?? "Mac" }
        set { defaults.set(newValue, forKey: ud_deviceName) }
    }

    public func ownIdentity(tcpPort: Int?) -> IdentityPayload {
        IdentityPayload(
            deviceId: deviceId,
            deviceName: deviceName,
            deviceType: .mac,
            protocolVersion: Self.protocolVersion,
            tcpPort: tcpPort,
            incomingCapabilities: PluginRegistry.shared.allIncomingCapabilities,
            outgoingCapabilities: PluginRegistry.shared.allOutgoingCapabilities
        )
    }

    public var trustedDeviceIds: Set<String> {
        get { Set(defaults.stringArray(forKey: ud_trustedDevices) ?? []) }
        set { defaults.set(Array(newValue), forKey: ud_trustedDevices) }
    }

    public func isTrusted(_ deviceId: String) -> Bool {
        trustedDeviceIds.contains(deviceId)
    }

    public func markTrusted(_ deviceId: String) {
        var s = trustedDeviceIds
        s.insert(deviceId)
        trustedDeviceIds = s
    }

    public func unmarkTrusted(_ deviceId: String) {
        var s = trustedDeviceIds
        s.remove(deviceId)
        trustedDeviceIds = s
    }

    private static func platformUUID() -> String? {
        let port = kIOMainPortDefault
        let svc = IOServiceGetMatchingService(port, IOServiceMatching("IOPlatformExpertDevice"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let prop = IORegistryEntryCreateCFProperty(svc, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return prop.takeRetainedValue() as? String
    }
}
