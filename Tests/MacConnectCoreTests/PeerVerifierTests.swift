import XCTest
import NIOSSL
@testable import MacConnectCore

/// Exercises the TOFU + pinning behaviour of `PeerVerifier` against a
/// throwaway `CertificateService` that owns its own temp directory. The
/// production singletons stay untouched.
final class PeerVerifierTests: XCTestCase {
    private var tempDir: URL!
    private var service: CertificateService!
    private var leafDER: Data!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("macconnect-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        service = CertificateService(rootDirectory: tempDir)
        try service.generateIdentity(forDeviceId: "peer_under_test")
        let pem = try Data(contentsOf: service.certificatePEMURL)
        leafDER = try Self.derFromPEM(pem)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testStoreAndLoadRoundTrip() {
        let deviceId = "peer_a"
        service.storeRemoteCertDER(deviceId: deviceId, der: leafDER)
        XCTAssertEqual(service.loadRemoteCertDER(deviceId: deviceId), leafDER)
    }

    func testFingerprintIsColonGroupedSha256() {
        let fp = service.sha256Fingerprint(ofDER: leafDER)
        XCTAssertEqual(fp.count, 64, "SHA-256 hex should be 64 chars before grouping")
        XCTAssertTrue(fp.allSatisfy { $0.isHexDigit })
    }
}

private extension PeerVerifierTests {
    /// Strip PEM armor and base64-decode to DER bytes.
    static func derFromPEM(_ pem: Data) throws -> Data {
        guard let pemString = String(data: pem, encoding: .utf8) else {
            throw NSError(domain: "PeerVerifierTests", code: 1)
        }
        let base64 = pemString
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let der = Data(base64Encoded: base64) else {
            throw NSError(domain: "PeerVerifierTests", code: 2)
        }
        return der
    }
}
