import Foundation

public enum PairPacketBuilder {
    public static func request() -> NetworkPacket {
        NetworkPacket(
            type: PacketType.pair,
            body: [
                "pair": .bool(true),
                "timestamp": .int(Int64(Date().timeIntervalSince1970)),
            ]
        )
    }

    public static func response(accept: Bool) -> NetworkPacket {
        NetworkPacket(
            type: PacketType.pair,
            body: ["pair": .bool(accept)]
        )
    }
}
