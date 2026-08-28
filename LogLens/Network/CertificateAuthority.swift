import Crypto
import Foundation
import NIOSSL
import SwiftASN1
import X509
import os

/// The LogLens root CA plus on-the-fly leaf certificates for intercepted hosts.
/// The CA key/cert live in Application Support so trust installed into simulators survives relaunches.
final class CertificateAuthority {

    private static let log = Logger(subsystem: "com.hugoprinsloo.LogLens", category: "CA")

    let directory: URL
    let certificatePath: String
    private let caCertificate: Certificate
    private let caKey: P256.Signing.PrivateKey
    private let leafKey: P256.Signing.PrivateKey
    private let leafKeyPEM: String
    private let caPEM: String
    /// SHA-256 of the DER certificate, hex. Used to detect CA rotation for simulator installs.
    let fingerprint: String
    let notValidAfter: Date

    private let lock = NSLock()
    private var contexts: [String: NIOSSLContext] = [:]

    // MARK: - Loading / generation

    static func load(directory: URL? = nil) throws -> CertificateAuthority {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LogLens/CA", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let certURL = dir.appendingPathComponent("LogLens-Root-CA.pem")
        let keyURL = dir.appendingPathComponent("LogLens-Root-CA-key.pem")

        if let certPEM = try? String(contentsOf: certURL, encoding: .utf8),
           let keyPEM = try? String(contentsOf: keyURL, encoding: .utf8),
           let key = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM),
           let cert = try? Certificate(pemEncoded: certPEM),
           cert.notValidAfter > Date().addingTimeInterval(30 * 86_400) {
            return try CertificateAuthority(directory: dir, certificate: cert, key: key)
        }

        let key = P256.Signing.PrivateKey()
        let cert = try makeRoot(key: key)
        try cert.serializeAsPEM().pemString.write(to: certURL, atomically: true, encoding: .utf8)
        try key.pemRepresentation.write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        log.info("Generated new LogLens root CA at \(dir.path)")
        return try CertificateAuthority(directory: dir, certificate: cert, key: key)
    }

    private init(directory: URL, certificate: Certificate, key: P256.Signing.PrivateKey) throws {
        self.directory = directory
        self.certificatePath = directory.appendingPathComponent("LogLens-Root-CA.pem").path
        self.caCertificate = certificate
        self.caKey = key
        self.leafKey = P256.Signing.PrivateKey()
        self.leafKeyPEM = leafKey.pemRepresentation
        self.caPEM = try certificate.serializeAsPEM().pemString
        var ser = DER.Serializer()
        try ser.serialize(certificate)
        self.fingerprint = SHA256.hash(data: Data(ser.serializedBytes)).map { String(format: "%02x", $0) }.joined()
        self.notValidAfter = certificate.notValidAfter
    }

    private static func makeRoot(key: P256.Signing.PrivateKey) throws -> Certificate {
        let privateKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            CommonName("LogLens Root CA (\(Host.current().localizedName ?? "Mac"))")
            OrganizationName("LogLens")
        }
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
            Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            SubjectKeyIdentifier(hash: privateKey.publicKey)
        }
        let now = Date()
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: privateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(10 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: privateKey
        )
    }

    // MARK: - Leaf certificates

    /// A cached TLS server context presenting a leaf certificate for `host`, signed by the root.
    func serverContext(for host: String) throws -> NIOSSLContext {
        let key = host.lowercased()
        lock.lock(); defer { lock.unlock() }
        if let ctx = contexts[key] { return ctx }
        let leaf = try mintLeaf(for: key)
        let leafPEM = try leaf.serializeAsPEM().pemString
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [
                .certificate(try NIOSSLCertificate(bytes: Array(leafPEM.utf8), format: .pem)),
                .certificate(try NIOSSLCertificate(bytes: Array(caPEM.utf8), format: .pem)),
            ],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leafKeyPEM.utf8), format: .pem))
        )
        // HTTP/1.1 only: never negotiate h2, so the proxy never has to speak HTTP/2.
        config.applicationProtocols = ["http/1.1"]
        config.minimumTLSVersion = .tlsv12
        let ctx = try NIOSSLContext(configuration: config)
        contexts[key] = ctx
        return ctx
    }

    private func mintLeaf(for host: String) throws -> Certificate {
        let leafPublic = Certificate.PrivateKey(leafKey).publicKey
        let issuerKey = Certificate.PrivateKey(caKey)
        let subject = try DistinguishedName {
            CommonName(host)
            OrganizationName("LogLens")
        }
        let san: GeneralName
        if let v4 = IPv4Address(host) {
            san = .ipAddress(ASN1OctetString(contentBytes: ArraySlice(v4.rawValue)))
        } else {
            san = .dnsName(host)
        }
        var caSKI: ArraySlice<UInt8>? = nil
        if let ski = try? caCertificate.extensions.subjectKeyIdentifier { caSKI = ski.keyIdentifier }
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([san])
            SubjectKeyIdentifier(hash: leafPublic)
            AuthorityKeyIdentifier(keyIdentifier: caSKI)
        }
        let now = Date()
        // Apple rejects TLS leaves valid for more than 825 days; keep well under.
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: leafPublic,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(397 * 86_400),
            issuer: caCertificate.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: issuerKey
        )
    }

    /// Lazily built client context used for the upstream leg (system trust roots, HTTP/1.1 only).
    private(set) lazy var clientContext: NIOSSLContext = {
        var config = TLSConfiguration.makeClientConfiguration()
        config.applicationProtocols = ["http/1.1"]
        return try! NIOSSLContext(configuration: config)
    }()
}

/// Minimal IPv4 literal parser so leaf certs for raw IP targets carry an iPAddress SAN.
struct IPv4Address {
    let rawValue: [UInt8]
    init?(_ s: String) {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts { guard let n = UInt8(p) else { return nil }; out.append(n) }
        rawValue = out
    }
}
