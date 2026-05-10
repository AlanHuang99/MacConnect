import Foundation
import Security

public final class CertificateService: @unchecked Sendable {
    public static let shared = CertificateService()

    private let queue = DispatchQueue(label: "macconnect.cert")
    private let appSupportDir: URL
    private let keyURL: URL
    private let certURL: URL
    private let p12URL: URL
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
        self.p12URL = dir.appendingPathComponent("identity.p12")
        self.trustedDir = trusted
    }

    public func ensureIdentity() throws {
        if FileManager.default.fileExists(atPath: certURL.path),
           FileManager.default.fileExists(atPath: keyURL.path),
           FileManager.default.fileExists(atPath: p12URL.path) {
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

        try runProcess("/usr/bin/openssl", [
            "pkcs12", "-export",
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-out", p12URL.path,
            "-passout", "pass:macconnect",
            "-name", "MacConnect",
        ])

        Log.pair.info("Generated TLS identity for deviceId=\(deviceId, privacy: .public)")
    }

    public func loadIdentity() throws -> SecIdentity {
        try ensureIdentity()
        let data = try Data(contentsOf: p12URL)
        let options: [String: Any] = [kSecImportExportPassphrase as String: "macconnect"]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let arr = items as? [[String: Any]],
              let first = arr.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "MacConnect.Cert", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "PKCS12 import failed (\(status))"])
        }
        return identity as! SecIdentity
    }

    public func storeRemoteCert(deviceId: String, cert: SecCertificate) {
        let data = SecCertificateCopyData(cert) as Data
        let url = trustedDir.appendingPathComponent("\(deviceId).der")
        try? data.write(to: url)
    }

    public func loadRemoteCert(deviceId: String) -> SecCertificate? {
        let url = trustedDir.appendingPathComponent("\(deviceId).der")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }

    public func deleteRemoteCert(deviceId: String) {
        let url = trustedDir.appendingPathComponent("\(deviceId).der")
        try? FileManager.default.removeItem(at: url)
    }

    public func sha256Fingerprint(of cert: SecCertificate) -> String {
        let data = SecCertificateCopyData(cert) as Data
        return data.sha256Hex
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
        let outData = try out.fileHandleForReading.readToEnd() ?? Data()
        let errData = try err.fileHandleForReading.readToEnd() ?? Data()
        if p.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "MacConnect.Process", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(exec) failed: \(msg)"])
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

import CryptoKit

extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
