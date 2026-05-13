import Foundation

public struct NetworkPacket: Sendable {
    public var id: Int64
    public var type: String
    public var body: [String: AnyJSON]
    public var payloadSize: Int64?
    public var payloadTransferInfo: [String: AnyJSON]?

    public init(
        type: String,
        body: [String: AnyJSON] = [:],
        payloadSize: Int64? = nil,
        payloadTransferInfo: [String: AnyJSON]? = nil
    ) {
        self.id = Int64(Date().timeIntervalSince1970 * 1000)
        self.type = type
        self.body = body
        self.payloadSize = payloadSize
        self.payloadTransferInfo = payloadTransferInfo
    }

    public func serialized() throws -> Data {
        var dict: [String: Any] = [
            "id": id,
            "type": type,
            "body": AnyJSON.dictionary(body).rawValue,
        ]
        if let payloadSize {
            dict["payloadSize"] = payloadSize
        }
        if let info = payloadTransferInfo {
            dict["payloadTransferInfo"] = AnyJSON.dictionary(info).rawValue
        }
        var data = try JSONSerialization.data(withJSONObject: dict, options: [])
        data.append(0x0A)
        return data
    }

    public static func parse(_ data: Data) throws -> NetworkPacket {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any],
              let type = dict["type"] as? String else {
            throw PacketError.malformed
        }
        let bodyDict: [String: Any] = (dict["body"] as? [String: Any]) ?? [:]
        let body = AnyJSON.toDictionary(bodyDict)
        let id = (dict["id"] as? Int64) ?? Int64((dict["id"] as? Int) ?? 0)
        var packet = NetworkPacket(type: type, body: body)
        packet.id = id
        if let size = dict["payloadSize"] as? Int64 {
            packet.payloadSize = size
        } else if let size = dict["payloadSize"] as? Int {
            packet.payloadSize = Int64(size)
        }
        if let info = dict["payloadTransferInfo"] as? [String: Any] {
            packet.payloadTransferInfo = AnyJSON.toDictionary(info)
        }
        return packet
    }
}

public enum PacketError: Error {
    case malformed
}

public extension NetworkPacket {
    /// Body key used to mark a `kdeconnect.ping` as a link-keepalive rather
    /// than a user-facing ping. Receivers MUST suppress the notification UI
    /// for pings carrying this flag.
    static let keepaliveBodyKey = "_keepalive"

    /// A ping packet flagged as a keepalive. Peers that don't recognise the
    /// flag will see it as an ordinary ping with no message; KDE Connect
    /// Android currently does this, which is harmless. Future versions of
    /// MacConnect (and KDE Connect Linux's pending heartbeat work) honour
    /// the flag.
    static func keepalive() -> NetworkPacket {
        NetworkPacket(
            type: PacketType.ping,
            body: [keepaliveBodyKey: .bool(true)]
        )
    }
}

public enum AnyJSON: Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case array([AnyJSON])
    case dictionary([String: AnyJSON])
    case null

    public var rawValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map(\.rawValue)
        case .dictionary(let v): return v.mapValues(\.rawValue)
        case .null: return NSNull()
        }
    }

    public static func from(_ value: Any) -> AnyJSON {
        if let v = value as? String { return .string(v) }
        if let v = value as? Bool { return .bool(v) }
        if let v = value as? Int64 { return .int(v) }
        if let v = value as? Int { return .int(Int64(v)) }
        if let v = value as? Double { return .double(v) }
        if let v = value as? [Any] { return .array(v.map(AnyJSON.from)) }
        if let v = value as? [String: Any] { return .dictionary(toDictionary(v)) }
        return .null
    }

    public static func toDictionary(_ d: [String: Any]) -> [String: AnyJSON] {
        d.mapValues(AnyJSON.from)
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    public var intValue: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        default: return nil
        }
    }
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    public var arrayValue: [AnyJSON]? {
        if case .array(let v) = self { return v }
        return nil
    }
    public var dictValue: [String: AnyJSON]? {
        if case .dictionary(let v) = self { return v }
        return nil
    }
}
