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
        let certs = try NIOSSLCertificate.fromPEMFile(CertificateService.shared.certificatePEMURL.path)
        let key = try NIOSSLPrivateKey(file: CertificateService.shared.privateKeyPEMURL.path, format: .pem)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        // Custom verification handles peer cert (TOFU + pinning); do not let
        // NIOSSL try to validate against system trust roots.
        config.certificateVerification = .none
        // KDE Connect supports TLS 1.2+. Some Linux peers still negotiate 1.2.
        config.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: config)
    }

    /// Custom verification callback bound to a known peer deviceId. Used for
    /// payload sub-connections where we already know who the peer must be.
    public static func verifier(forKnownDeviceId deviceId: String) -> NIOSSLCustomVerificationCallback {
        { peerCerts, promise in
            let result = PeerVerifier.verify(deviceId: deviceId, peerCerts: peerCerts)
            switch result {
            case .accepted, .pinnedMatch:
                promise.succeed(.certificateVerified)
            case .pinnedMismatch, .missing:
                Log.pair
                    .error(
                        "Payload TLS verify failed for \(deviceId, privacy: .public): \(String(describing: result), privacy: .public)"
                    )
                promise.succeed(.failed)
            }
        }
    }
}

/// Result of a peer-cert verification attempt.
public enum PeerVerification: Equatable {
    case accepted // first pairing — TOFU
    case pinnedMatch // already paired and cert matches stored pin
    /// Already paired but cert changed — refuse. The associated value is the
    /// colon-grouped SHA-256 of the cert the peer just presented, so the UI
    /// can show the user what changed.
    case pinnedMismatch(presentedFingerprint: String)
    case missing // peer presented no cert
}

public enum PeerVerifier {
    /// Verify a peer's leaf certificate against our trust state.
    /// Stores the cert as the "pending" pin if not yet paired (TOFU).
    public static func verify(deviceId: String, peerCerts: [NIOSSLCertificate]) -> PeerVerification {
        guard let leaf = peerCerts.first else { return .missing }
        let der: Data
        do {
            der = try Data(leaf.toDERBytes())
        } catch {
            Log.pair
                .error(
                    "toDERBytes failed for \(deviceId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            return .missing
        }
        let isTrusted = Settings.shared.isTrusted(deviceId)
        if isTrusted {
            guard let pinned = CertificateService.shared.loadRemoteCertDER(deviceId: deviceId) else {
                // Trusted but no pin on disk; rebuild the pin from this cert.
                CertificateService.shared.storeRemoteCertDER(deviceId: deviceId, der: der)
                return .pinnedMatch
            }
            if pinned == der { return .pinnedMatch }
            let hex = CertificateService.shared.sha256Fingerprint(ofDER: der)
            return .pinnedMismatch(presentedFingerprint: Self.colonGrouped(hex))
        }
        // Not yet paired: TOFU — store as pending pin so pair-accept can promote it.
        CertificateService.shared.storeRemoteCertDER(deviceId: deviceId, der: der)
        return .accepted
    }

    private static func colonGrouped(_ hex: String) -> String {
        var out = ""
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if !out.isEmpty { out.append(":") }
            out.append(contentsOf: hex[i ..< j])
            i = j
        }
        return out
    }
}
