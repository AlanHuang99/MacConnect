import Foundation

public struct IdentityPayload: Sendable {
    public var deviceId: String
    public var deviceName: String
    public var deviceType: DeviceType
    public var protocolVersion: Int
    public var tcpPort: Int?
    public var incomingCapabilities: [String]
    public var outgoingCapabilities: [String]

    public func toPacket() -> NetworkPacket {
        var body: [String: AnyJSON] = [
            "deviceId": .string(deviceId),
            "deviceName": .string(deviceName),
            "deviceType": .string(deviceType.rawValue),
            "protocolVersion": .int(Int64(protocolVersion)),
            "incomingCapabilities": .array(incomingCapabilities.map { .string($0) }),
            "outgoingCapabilities": .array(outgoingCapabilities.map { .string($0) }),
        ]
        if let port = tcpPort {
            body["tcpPort"] = .int(Int64(port))
        }
        return NetworkPacket(type: PacketType.identity, body: body)
    }

    public static func from(packet: NetworkPacket) -> IdentityPayload? {
        guard packet.type == PacketType.identity,
              let id = packet.body["deviceId"]?.stringValue,
              let name = packet.body["deviceName"]?.stringValue,
              let typeStr = packet.body["deviceType"]?.stringValue,
              let type = DeviceType(rawValue: typeStr),
              let proto = packet.body["protocolVersion"]?.intValue
        else { return nil }
        let port = packet.body["tcpPort"]?.intValue.map(Int.init)
        let incoming = (packet.body["incomingCapabilities"]?.arrayValue ?? []).compactMap(\.stringValue)
        let outgoing = (packet.body["outgoingCapabilities"]?.arrayValue ?? []).compactMap(\.stringValue)
        return IdentityPayload(
            deviceId: id,
            deviceName: name,
            deviceType: type,
            protocolVersion: Int(proto),
            tcpPort: port,
            incomingCapabilities: incoming,
            outgoingCapabilities: outgoing
        )
    }
}
