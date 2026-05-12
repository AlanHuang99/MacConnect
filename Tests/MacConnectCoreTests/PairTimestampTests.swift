import XCTest
@testable import MacConnectCore

final class PairTimestampTests: XCTestCase {
    /// KDE Connect Android compares the pair timestamp in milliseconds and
    /// rejects values that look like seconds. The previous implementation
    /// emitted seconds, which Android tolerated but newer protocol-strict
    /// peers would not.
    func testPairRequestTimestampIsMilliseconds() {
        let beforeMs = Int64(Date().timeIntervalSince1970 * 1000)
        let packet = PairPacketBuilder.request()
        let afterMs = Int64(Date().timeIntervalSince1970 * 1000)

        let timestamp = packet.body["timestamp"]?.intValue ?? 0
        // Must be in millisecond range — 13 digits as of 2001-09-09.
        XCTAssertGreaterThan(timestamp, 1_000_000_000_000, "Expected ms-scale timestamp")
        XCTAssertGreaterThanOrEqual(timestamp, beforeMs - 1)
        XCTAssertLessThanOrEqual(timestamp, afterMs + 1)
    }
}
