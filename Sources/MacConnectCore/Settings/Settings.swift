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
            // Capability lists in PluginRegistry derive from this set;
            // invalidate at the underlying setter so any code path that
            // mutates disabledPluginIds (not just setPluginEnabled) keeps
            // identity broadcasts in sync with the new state.
            PluginRegistry.shared.invalidateCapabilityCache()
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    public func isPluginEnabled(_ pluginId: String) -> Bool {
        !disabledPluginIds.contains(pluginId)
    }

    public func setPluginEnabled(_ pluginId: String, _ enabled: Bool) {
        var s = disabledPluginIds
        if enabled { s.remove(pluginId) } else { s.insert(pluginId) }
        // Cache invalidation now lives in the disabledPluginIds setter.
        disabledPluginIds = s
    }

    // MARK: - Per-device plugin overrides

    //
    // Layered on top of the global enable/disable: a plugin reaches the
    // dispatcher for a given peer only if it is globally enabled AND not
    // in that peer's per-device disabled set. Per-device overrides do
    // not affect outgoing capability advertisement — the peer still sees
    // us as capable; we just silently drop inbound packets we don't want.

    private let ud_disabledPluginsByDevice = "macconnect.disabledPluginsByDevice"

    /// Dictionary keyed by deviceId → set of plugin identifiers the user
    /// has explicitly disabled for that peer.
    public var disabledPluginsByDevice: [String: Set<String>] {
        get {
            guard let raw = defaults.dictionary(forKey: ud_disabledPluginsByDevice) as? [String: [String]] else {
                return [:]
            }
            return raw.mapValues(Set.init)
        }
        set {
            let raw = newValue.mapValues(Array.init)
            defaults.set(raw, forKey: ud_disabledPluginsByDevice)
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    public func isPluginEnabled(_ pluginId: String, forDevice deviceId: String) -> Bool {
        guard isPluginEnabled(pluginId) else { return false }
        return !(disabledPluginsByDevice[deviceId]?.contains(pluginId) ?? false)
    }

    public func setPluginEnabled(_ pluginId: String, _ enabled: Bool, forDevice deviceId: String) {
        var all = disabledPluginsByDevice
        var s = all[deviceId] ?? []
        if enabled { s.remove(pluginId) } else { s.insert(pluginId) }
        if s.isEmpty {
            all.removeValue(forKey: deviceId)
        } else {
            all[deviceId] = s
        }
        disabledPluginsByDevice = all
    }

    /// Drop all per-device overrides for a peer — called when the user
    /// unpairs / forgets that peer.
    public func clearPerDevicePluginOverrides(forDevice deviceId: String) {
        var all = disabledPluginsByDevice
        all.removeValue(forKey: deviceId)
        disabledPluginsByDevice = all
    }

    private static func platformUUID() -> String? {
        let port = kIOMainPortDefault
        let svc = IOServiceGetMatchingService(port, IOServiceMatching("IOPlatformExpertDevice"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let prop = IORegistryEntryCreateCFProperty(svc, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        else {
            return nil
        }
        return prop.takeRetainedValue() as? String
    }
}
