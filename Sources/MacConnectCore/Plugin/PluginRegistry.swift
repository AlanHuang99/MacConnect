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

    public var allIncomingCapabilities: [String] {
        Array(Set(plugins.flatMap(\.incomingCapabilities))).sorted()
    }

    public var allOutgoingCapabilities: [String] {
        Array(Set(plugins.flatMap(\.outgoingCapabilities))).sorted()
    }

    public func plugin(handling type: String) -> Plugin? {
        plugins.first { $0.incomingCapabilities.contains(type) }
    }

    @MainActor
    public func dispatch(_ packet: NetworkPacket, from device: Device) async {
        for p in plugins where p.incomingCapabilities.contains(packet.type) {
            await p.handle(packet: packet, from: device)
        }
    }
}
