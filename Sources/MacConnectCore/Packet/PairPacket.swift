import Foundation

public enum PairPacketBuilder {
    public static func request() -> NetworkPacket {
        NetworkPacket(
            type: PacketType.pair,
            body: [
                "pair": .bool(true),
                // KDE Connect's protocol expects this as milliseconds since
                // epoch (Android: `System.currentTimeMillis()`); seconds
                // would be ~1e9 and indistinguishable from a bug-clocked
                // peer. Some Android builds reject seconds-scale values.
                "timestamp": .int(Int64(Date().timeIntervalSince1970 * 1000))
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
