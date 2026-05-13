@testable import MacConnectCore
import XCTest

final class PacketTests: XCTestCase {
    func testIdentityRoundTrip() throws {
        let id = IdentityPayload(
            deviceId: "test_id",
            deviceName: "Test Mac",
            deviceType: .laptop,
            protocolVersion: 7,
            tcpPort: 1716,
            incomingCapabilities: [PacketType.ping, PacketType.clipboard],
            outgoingCapabilities: [PacketType.ping]
        )
        let data = try id.toPacket().serialized()
        XCTAssertTrue(data.last == 0x0A, "Must end with newline framing")

        let payload = data.dropLast()
        let parsed = try NetworkPacket.parse(payload)
        XCTAssertEqual(parsed.type, PacketType.identity)
        let parsedId = IdentityPayload.from(packet: parsed)
        XCTAssertNotNil(parsedId)
        XCTAssertEqual(parsedId?.deviceId, "test_id")
        XCTAssertEqual(parsedId?.deviceName, "Test Mac")
        XCTAssertEqual(parsedId?.tcpPort, 1716)
        XCTAssertEqual(parsedId?.incomingCapabilities.sorted(), [PacketType.clipboard, PacketType.ping].sorted())
    }

    func testPingPacket() throws {
        let p = NetworkPacket(type: PacketType.ping, body: ["message": .string("hi")])
        let data = try p.serialized()
        let parsed = try NetworkPacket.parse(data.dropLast())
        XCTAssertEqual(parsed.type, PacketType.ping)
        XCTAssertEqual(parsed.body["message"]?.stringValue, "hi")
    }

    func testPairRequest() {
        let p = PairPacketBuilder.request()
        XCTAssertEqual(p.type, PacketType.pair)
        XCTAssertEqual(p.body["pair"]?.boolValue, true)
        XCTAssertNotNil(p.body["timestamp"]?.intValue)
    }
}
