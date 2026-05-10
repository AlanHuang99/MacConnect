import Foundation
import CryptoKit

/// Manages the local TLS identity (RSA-2048 self-signed certificate + private
/// key) and the on-disk store of pinned remote-peer certs.
///
/// The local cert and key are written as PEM under
/// `~/Library/Application Support/MacConnect/`. They are produced via the
/// system `openssl` binary on first run and reused afterwards.
public final class CertificateService: @unchecked Sendable {
    public static let shared = CertificateService()

    private let lock = NSLock()
    private let appSupportDir: URL
    private let keyURL: URL
    private let certURL: URL
    private let trustedDir: URL

    public init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MacConnect", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let trusted = dir.appendingPathComponent("trusted-certs", isDirectory: true)
        try? fm.createDirectory(at: trusted, withIntermediateDirectories: true)
        self.appSupportDir = dir
        self.keyURL = dir.appendingPathComponent("key.pem")
        self.certURL = dir.appendingPathComponent("cert.pem")
        self.trustedDir = trusted
    }

    public var certificatePEMURL: URL { certURL }
    public var privateKeyPEMURL: URL { keyURL }

    public func ensureIdentity() throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: certURL.path),
           FileManager.default.fileExists(atPath: keyURL.path) {
            return
        }
        try generateIdentity()
    }

    private func generateIdentity() throws {
        let deviceId = Settings.shared.deviceId
        let subject = "/O=KDE/OU=KDE Connect/CN=\(deviceId)"

        try runProcess("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-sha256",
            "-days", "3650",
            "-nodes",
            "-subj", subject,
        ])

        Log.pair.info("Generated TLS identity for deviceId=\(deviceId, privacy: .public)")
    }

    public func storeRemoteCertDER(deviceId: String, der: Data) {
        let url = trustedDir.appendingPathComponent("\(deviceId).der")
        do {
            try der.write(to: url)
        } catch {
            Log.pair.error("Failed to store cert for \(deviceId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func loadRemoteCertDER(deviceId: String) -> Data? {
        let url = trustedDir.appendingPathComponent("\(deviceId).der")
        return try? Data(contentsOf: url)
    }

    public func deleteRemoteCert(deviceId: String) {
        let url = trustedDir.appendingPathComponent("\(deviceId).der")
        try? FileManager.default.removeItem(at: url)
    }

    public func sha256Fingerprint(ofDER der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 fingerprint of the local cert, formatted with colons
    /// (`aa:bb:cc:...`) so users can read it aloud or compare visually
    /// against another KDE Connect implementation's display.
    public func localFingerprint() -> String? {
        guard let der = localCertDER() else { return nil }
        let hex = sha256Fingerprint(ofDER: der)
        return Self.colonGroupedHex(hex)
    }

    public func fingerprint(forTrustedDeviceId deviceId: String) -> String? {
        guard let der = loadRemoteCertDER(deviceId: deviceId) else { return nil }
        let hex = sha256Fingerprint(ofDER: der)
        return Self.colonGroupedHex(hex)
    }

    private func localCertDER() -> Data? {
        guard let pemData = try? Data(contentsOf: certURL),
              let pemString = String(data: pemData, encoding: .utf8) else {
            return nil
        }
        let base64 = pemString
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        return Data(base64Encoded: base64)
    }

    private static func colonGroupedHex(_ hex: String) -> String {
        var out = ""
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if !out.isEmpty { out.append(":") }
            out.append(contentsOf: hex[i..<j])
            i = j
        }
        return out
    }

    @discardableResult
    private func runProcess(_ exec: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exec)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
        if p.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "MacConnect.Process",
                code: Int(p.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(exec) failed: \(msg)"]
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
