import Foundation
import IOKit

public final class Settings: ObservableObject, @unchecked Sendable {
    public static let shared = Settings()

    private let defaults = UserDefaults.standard
    private let ud_deviceId = "macconnect.deviceId"
    private let ud_deviceName = "macconnect.deviceName"
    private let ud_trustedDevices = "macconnect.trustedDevices"
    private let ud_disabledPlugins = "macconnect.disabledPlugins"

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
        set {
            // KDE Connect protocol forbids these characters in deviceName
            let forbidden = CharacterSet(charactersIn: "\"',;:.!?()[]<>")
            let sanitized = newValue
                .components(separatedBy: forbidden).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clamped = sanitized.isEmpty ? "Mac" : String(sanitized.prefix(32))
            defaults.set(clamped, forKey: ud_deviceName)
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
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

    public var disabledPluginIds: Set<String> {
        get { Set(defaults.stringArray(forKey: ud_disabledPlugins) ?? []) }
        set {
            defaults.set(Array(newValue), forKey: ud_disabledPlugins)
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    public func isPluginEnabled(_ pluginId: String) -> Bool {
        !disabledPluginIds.contains(pluginId)
    }

    public func setPluginEnabled(_ pluginId: String, _ enabled: Bool) {
        var s = disabledPluginIds
        if enabled { s.remove(pluginId) } else { s.insert(pluginId) }
        disabledPluginIds = s
        // Capability lists derive from this set; flush the cache so the
        // next identity broadcast advertises the new state.
        PluginRegistry.shared.invalidateCapabilityCache()
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
