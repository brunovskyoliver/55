#if os(macOS)
import CryptoKit
import Foundation
@preconcurrency import Security

/// Generates and persists a self-signed TLS identity used by `LocalControlAPIServer`.
/// The identity (PKCS#12) is stored in Application Support and reloaded on subsequent runs.
/// The cert's SHA-256 fingerprint is embedded in `PairingInvitation` so the iPhone can pin.
public struct SelfSignedTLSIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    /// Lowercase hex SHA-256 fingerprint of the DER-encoded leaf certificate.
    public let certFingerprintSHA256: String

    // MARK: - Public API

    public static func loadOrCreate(
        executor: any ProcessCommandExecuting = FoundationProcessCommandExecutor()
    ) throws -> SelfSignedTLSIdentity {
        let p12URL = try p12FileURL()

        if FileManager.default.fileExists(atPath: p12URL.path) {
            if let existing = try? load(from: p12URL) {
                return existing
            }
            // If load fails (e.g. corrupt file), regenerate.
            try? FileManager.default.removeItem(at: p12URL)
        }

        return try generate(at: p12URL, executor: executor)
    }

    // MARK: - Private

    private static let p12Password = "AgentSessionControl"
    private static let p12FileName = "AgentSessionControl-TLS.p12"

    private static func generate(
        at p12URL: URL,
        executor: any ProcessCommandExecuting
    ) throws -> SelfSignedTLSIdentity {
        let dir = p12URL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let keyURL = dir.appendingPathComponent("AgentSessionControl-TLS.key.pem")
        let certURL = dir.appendingPathComponent("AgentSessionControl-TLS.cert.pem")

        defer {
            try? FileManager.default.removeItem(at: keyURL)
            try? FileManager.default.removeItem(at: certURL)
        }

        // Generate private key + self-signed certificate (10-year validity).
        _ = try executor.run(executable: "openssl", arguments: [
            "req", "-x509",
            "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", "3650",
            "-nodes",
            "-subj", "/CN=AgentSessionControl"
        ])

        // Export to PKCS#12. Try with -legacy first (OpenSSL 3.x) then without (LibreSSL).
        let p12Args = [
            "pkcs12", "-export",
            "-out", p12URL.path,
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-passout", "pass:\(p12Password)"
        ]
        if (try? executor.run(executable: "openssl", arguments: p12Args + ["-legacy"])) == nil {
            _ = try executor.run(executable: "openssl", arguments: p12Args)
        }

        return try load(from: p12URL)
    }

    private static func load(from p12URL: URL) throws -> SelfSignedTLSIdentity {
        let p12Data = try Data(contentsOf: p12URL)
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Password]
        var rawItems: CFArray?

        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let first = items.first,
              let identityRef = first[kSecImportItemIdentity as String] as CFTypeRef?,
              CFGetTypeID(identityRef) == SecIdentityGetTypeID()
        else {
            throw SelfSignedTLSIdentityError.importFailed(status)
        }
        // Safe force cast — we validated the TypeID above.
        let identity = identityRef as! SecIdentity

        var certRef: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &certRef)
        guard certStatus == errSecSuccess, let cert = certRef else {
            throw SelfSignedTLSIdentityError.certCopyFailed
        }

        let fingerprint = sha256Fingerprint(of: cert)
        return SelfSignedTLSIdentity(identity: identity, certFingerprintSHA256: fingerprint)
    }

    private static func sha256Fingerprint(of cert: SecCertificate) -> String {
        let derData = SecCertificateCopyData(cert) as Data
        return SHA256.hash(data: derData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func p12FileURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AgentSessionControl", isDirectory: true)
            .appendingPathComponent(p12FileName)
    }
}

public enum SelfSignedTLSIdentityError: Error, Equatable {
    case importFailed(OSStatus)
    case certCopyFailed
}
#endif
