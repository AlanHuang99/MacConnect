import Foundation
import NIOCore
import NIOSSL

/// Builds NIOSSL contexts wired to our self-signed RSA identity.
///
/// KDE Connect uses mutual TLS with self-signed peer certs; trust is "TOFU on
/// first pair, pin on subsequent connections". We disable NIOSSL's built-in
/// verification (`.none` on the configuration) and do our own check via the
/// per-handler `customVerificationCallback`.
public enum TLSContextBuilder {
    public static func makeContext() throws -> NIOSSLContext {
        try CertificateService.shared.ensureIdentity()
        let cert = try NIOSSLCertificate(file: CertificateService.shared.certificatePEMURL.path, format: .pem)
        let key = try NIOSSLPrivateKey(file: CertificateService.shared.privateKeyPEMURL.path, format: .pem)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(cert)],
            privateKey: .privateKey(key)
        )
        // Custom verification handles peer cert (TOFU + pinning); do not let
        // NIOSSL try to validate against system trust roots.
        config.certificateVerification = .none
        // KDE Connect supports TLS 1.2+. Some Linux peers still negotiate 1.2.
        config.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: config)
    }
}

/// Result of a peer-cert verification attempt.
public enum PeerVerification {
    case accepted          // first pairing — TOFU
    case pinnedMatch       // already paired and cert matches stored pin
    case pinnedMismatch    // already paired but cert changed — refuse
    case missing           // peer presented no cert
}

public enum PeerVerifier {
    /// Verify a peer's leaf certificate against our trust state.
    /// Stores the cert as the "pending" pin if not yet paired (TOFU).
    public static func verify(deviceId: String, peerCerts: [NIOSSLCertificate]) -> PeerVerification {
        guard let leaf = peerCerts.first else { return .missing }
        let der = Data(try! leaf.toDERBytes())
        let isTrusted = Settings.shared.isTrusted(deviceId)
        if isTrusted {
            guard let pinned = CertificateService.shared.loadRemoteCertDER(deviceId: deviceId) else {
                // Trusted but no pin on disk — should not happen, but be defensive
                CertificateService.shared.storeRemoteCertDER(deviceId: deviceId, der: der)
                return .pinnedMatch
            }
            return pinned == der ? .pinnedMatch : .pinnedMismatch
        } else {
            // Not yet paired: store as pending pin so pair-accept can promote it
            CertificateService.shared.storeRemoteCertDER(deviceId: deviceId, der: der)
            return .accepted
        }
    }
}
