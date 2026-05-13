import Foundation

public final class PluginRegistry: @unchecked Sendable {
    public static let shared = PluginRegistry()

    private let queue = DispatchQueue(label: "macconnect.pluginregistry")
    private var _plugins: [Plugin] = []
    /// Cached enabled-plugin capability lists. Identity broadcasts read these
    /// every 5 s; recomputing meant set-build + sort each tick. Cache is
    /// invalidated on registration and on plugin enable/disable.
    private var cachedIncoming: [String]?
    private var cachedOutgoing: [String]?

    public init() {}

    public func register(_ plugin: Plugin) {
        queue.sync {
            _plugins.append(plugin)
            cachedIncoming = nil
            cachedOutgoing = nil
        }
    }

    /// Drop the cached capability lists. `Settings.setPluginEnabled` calls
    /// this so broadcasts pick up new state on the next refresh.
    public func invalidateCapabilityCache() {
        queue.sync {
            cachedIncoming = nil
            cachedOutgoing = nil
        }
    }

    public var plugins: [Plugin] {
        queue.sync { _plugins }
    }

    /// All registered plugins, including ones the user disabled. Use for UI
    /// (the Settings toggle list); dispatch and capability advertisement
    /// should both go through `enabledPlugins` so disabled plugins are
    /// invisible to peers.
    public var allPlugins: [Plugin] { plugins }

    public var enabledPlugins: [Plugin] {
        plugins.filter { Settings.shared.isPluginEnabled($0.identifier) }
    }

    public var allIncomingCapabilities: [String] {
        queue.sync {
            if let cachedIncoming { return cachedIncoming }
            let enabled = _plugins.filter { Settings.shared.isPluginEnabled($0.identifier) }
            let value = Array(Set(enabled.flatMap(\.incomingCapabilities))).sorted()
            cachedIncoming = value
            return value
        }
    }

    public var allOutgoingCapabilities: [String] {
        queue.sync {
            if let cachedOutgoing { return cachedOutgoing }
            let enabled = _plugins.filter { Settings.shared.isPluginEnabled($0.identifier) }
            let value = Array(Set(enabled.flatMap(\.outgoingCapabilities))).sorted()
            cachedOutgoing = value
            return value
        }
    }

    @MainActor
    public func dispatch(_ packet: NetworkPacket, from device: Device) async {
        let deviceId = device.id
        for p in enabledPlugins where p.incomingCapabilities.contains(packet.type) {
            // Layer per-device overrides on top of the global enable
            // check that `enabledPlugins` already applies.
            guard Settings.shared.isPluginEnabled(p.identifier, forDevice: deviceId) else { continue }
            await p.handle(packet: packet, from: device)
        }
    }
}
