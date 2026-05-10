import Foundation

public final class PluginRegistry: @unchecked Sendable {
    public static let shared = PluginRegistry()

    private let queue = DispatchQueue(label: "macconnect.pluginregistry")
    private var _plugins: [Plugin] = []

    public init() {}

    public func register(_ plugin: Plugin) {
        queue.sync { _plugins.append(plugin) }
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
        Array(Set(enabledPlugins.flatMap(\.incomingCapabilities))).sorted()
    }

    public var allOutgoingCapabilities: [String] {
        Array(Set(enabledPlugins.flatMap(\.outgoingCapabilities))).sorted()
    }

    @MainActor
    public func dispatch(_ packet: NetworkPacket, from device: Device) async {
        for p in enabledPlugins where p.incomingCapabilities.contains(packet.type) {
            await p.handle(packet: packet, from: device)
        }
    }
}
