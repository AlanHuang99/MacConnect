import Foundation

public protocol Plugin: AnyObject, Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var incomingCapabilities: [String] { get }
    var outgoingCapabilities: [String] { get }

    @MainActor func handle(packet: NetworkPacket, from device: Device) async
    @MainActor func attach(to device: Device) async
    @MainActor func detach(from device: Device) async
}

public extension Plugin {
    @MainActor func attach(to _: Device) async {}
    @MainActor func detach(from _: Device) async {}
}
