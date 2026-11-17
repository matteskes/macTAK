// IdentityStore.swift — client certificates and truststores in the Keychain (G3.2b).
//
// commo takes a client identity and a CA as PKCS#12 bytes and passwords
// (TLSCredentials). The store keeps them in a file-based keychain: the
// login keychain in the app, or a throwaway one in tests
// (Support/TemporaryKeychain.swift, which alone uses the deprecated
// SecKeychainCreate, so the library has no deprecated call). The data
// protection keychain needs a team-ID entitlement, which the ad-hoc-signed
// development bundle can't have (dev/g3/NOTES.md §G3.2).
//
// - A client identity is a real Keychain identity: the private key is the
//   Keychain's. `credentials` exports it as PKCS#12 under a random password,
//   in memory, each time commo needs it. Apple's export uses legacy
//   algorithms (RC2-40, 3DES), which commo reads because it loads OpenSSL's
//   legacy provider, as it must for ATAK's own .p12 files.
// - A truststore is public data, and the Keychain can't export certificates
//   alone as PKCS#12 (SecItemExport returns -50), so it is kept as the
//   PKCS#12 bytes and password it came with, in one generic-password item.
//
// Both are named by the SHA-256 of a certificate (the client's own, or the
// truststore's first). Every .p12 is parsed in memory first
// (kSecImportToMemoryOnly), so a wrong password or a malformed file never
// touches a keychain, and importing the same identity twice is harmless.
// Nothing here does TLS: commo and OpenSSL 3 do (§G3.2, one TLS stack).

import CryptoKit
import Foundation
import Security

/// The SHA-256 of a certificate's DER bytes, as lowercase hex.
public struct Fingerprint: Hashable, Codable, Sendable, CustomStringConvertible {
    public let hex: String

    init(_ certificate: SecCertificate) {
        let der = SecCertificateCopyData(certificate) as Data
        hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { String(hex.prefix(16)) }
}

public struct IdentityError: Error, CustomStringConvertible, Equatable {
    public let description: String
    init(_ description: String) { self.description = description }
    init(_ what: String, _ status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        description = "\(what): \(message) (\(status))"
    }
}

public final class IdentityStore: @unchecked Sendable {
    /// nil: the default keychain (the user's login keychain).
    let keychain: SecKeychain?

    private static let truststoreService = "macTAK truststore"

    /// The user's login keychain.
    public static let login = IdentityStore(keychain: nil)

    /// A store over `keychain`; the tests' throwaway keychains come in here.
    init(keychain: SecKeychain?) {
        self.keychain = keychain
    }

    // MARK: - client identities

    /// Imports a client identity (its certificate and private key) from
    /// PKCS#12; returns its certificate's fingerprint.
    @discardableResult
    public func importIdentity(pkcs12: Data, password: String) throws -> Fingerprint {
        let parsed = try Self.parse(pkcs12, password: password)
        guard let identity = parsed.identity else {
            throw IdentityError("the PKCS#12 carries no private key, so it is not a client identity")
        }
        let fingerprint = try Self.fingerprint(of: identity)
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if let keychain { options[kSecImportExportKeychain as String] = keychain }
        var items: CFArray?
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw IdentityError("importing the identity", status) }
        return fingerprint
    }

    /// The fingerprints and subjects of the client identities in the keychain.
    public func identities() throws -> [(fingerprint: Fingerprint, subject: String)] {
        try allIdentities().map { identity in
            let certificate = try Self.certificate(of: identity)
            return (Fingerprint(certificate), SecCertificateCopySubjectSummary(certificate) as String? ?? "?")
        }
    }

    public func removeIdentity(_ fingerprint: Fingerprint) throws {
        let identity = try findIdentity(fingerprint)
        var query = searchQuery(kSecClassIdentity)
        query[kSecValueRef as String] = identity
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess else { throw IdentityError("removing identity \(fingerprint)", status) }
    }

    // MARK: - truststores

    /// Keeps a truststore (CA certificates) as the PKCS#12 bytes and
    /// password it came with; returns its first certificate's fingerprint.
    /// Importing it again replaces the stored copy.
    @discardableResult
    public func importTruststore(pkcs12: Data, password: String) throws -> Fingerprint {
        let parsed = try Self.parse(pkcs12, password: password)
        guard let first = parsed.chain.first else { throw IdentityError("the truststore carries no certificate") }
        let fingerprint = Fingerprint(first)
        let blob = try PropertyListEncoder().encode(Truststore(pkcs12: pkcs12, password: password))
        try? removeTruststore(fingerprint)
        var item = truststoreQuery(fingerprint)
        item[kSecValueData as String] = blob
        item[kSecAttrLabel as String] = "macTAK truststore \(SecCertificateCopySubjectSummary(first) as String? ?? "")"
        if let keychain { item[kSecUseKeychain as String] = keychain }
        item.removeValue(forKey: kSecMatchSearchList as String)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError("storing the truststore", status) }
        return fingerprint
    }

    public func removeTruststore(_ fingerprint: Fingerprint) throws {
        let status = SecItemDelete(truststoreQuery(fingerprint) as CFDictionary)
        guard status == errSecSuccess else { throw IdentityError("removing truststore \(fingerprint)", status) }
    }

    // MARK: - for commo

    /// The identity and truststore as commo takes them: the identity
    /// exported under a fresh random password, both in memory only.
    public func credentials(identity: Fingerprint, truststore: Fingerprint) throws -> TLSCredentials {
        let item = try findIdentity(identity)
        let password = try Self.randomPassword()
        let passphrase = password as CFString
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        var exported: CFData?
        let status = withExtendedLifetime(passphrase) {
            parameters.passphrase = Unmanaged.passUnretained(passphrase)
            return SecItemExport(item, .formatPKCS12, [], &parameters, &exported)
        }
        guard status == errSecSuccess, let exported else {
            throw IdentityError("exporting identity \(identity)", status)
        }
        let trust = try loadTruststore(truststore)
        return TLSCredentials(identity: exported as Data, identityPassword: password,
                              ca: trust.pkcs12, caPassword: trust.password)
    }

    // MARK: - details

    private struct Truststore: Codable {
        let pkcs12: Data
        let password: String
    }

    /// The truststore as commo takes it.
    public func truststore(_ fingerprint: Fingerprint) throws -> TLSTruststore {
        let stored = try loadTruststore(fingerprint)
        return TLSTruststore(pkcs12: stored.pkcs12, password: stored.password)
    }

    /// The truststore's certificates as PEM, as curl takes them
    /// (TakHTTPS.get). Parsed in memory only.
    public func truststorePEM(_ fingerprint: Fingerprint) throws -> Data {
        let stored = try loadTruststore(fingerprint)
        let certificates = try Self.parse(stored.pkcs12, password: stored.password).chain
        guard !certificates.isEmpty else { throw IdentityError("truststore \(fingerprint) carries no certificate") }
        return Data(certificates.map { certificate in
            let base64 = (SecCertificateCopyData(certificate) as Data).base64EncodedString(options: .lineLength64Characters)
            return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
        }.joined().utf8)
    }

    private func loadTruststore(_ fingerprint: Fingerprint) throws -> Truststore {
        var query = truststoreQuery(fingerprint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw IdentityError("no truststore \(fingerprint) in the keychain", status)
        }
        return try PropertyListDecoder().decode(Truststore.self, from: data)
    }

    private func truststoreQuery(_ fingerprint: Fingerprint) -> [String: Any] {
        var query = searchQuery(kSecClassGenericPassword)
        query[kSecAttrService as String] = Self.truststoreService
        query[kSecAttrAccount as String] = fingerprint.hex
        return query
    }

    /// A query scoped to this store's keychain.
    private func searchQuery(_ itemClass: CFString) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: itemClass]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    private func allIdentities() throws -> [SecIdentity] {
        var query = searchQuery(kSecClassIdentity)
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw IdentityError("listing identities", status) }
        return (result as? [SecIdentity]) ?? []
    }

    private func findIdentity(_ fingerprint: Fingerprint) throws -> SecIdentity {
        for identity in try allIdentities() where try Self.fingerprint(of: identity) == fingerprint {
            return identity
        }
        throw IdentityError("no identity \(fingerprint) in the keychain")
    }

    /// Parses a PKCS#12 in memory only: nothing reaches a keychain.
    private static func parse(_ pkcs12: Data, password: String) throws -> (identity: SecIdentity?, chain: [SecCertificate]) {
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password,
                                      kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw IdentityError("reading the PKCS#12", status) }
        let first = (items as? [[String: Any]])?.first
        let identity = first?[kSecImportItemIdentity as String].map { $0 as! SecIdentity }
        return (identity, (first?[kSecImportItemCertChain as String] as? [SecCertificate]) ?? [])
    }

    private static func certificate(of identity: SecIdentity) throws -> SecCertificate {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let certificate else { throw IdentityError("reading a certificate", status) }
        return certificate
    }

    private static func fingerprint(of identity: SecIdentity) throws -> Fingerprint {
        Fingerprint(try certificate(of: identity))
    }

    private static func randomPassword() throws -> String { try TLSTruststore.randomPassword() }
}
