// ServerConfig.swift — one TAK server connection, as the app keeps it (G3.2b).
//
// What a data package's cot_streams entry becomes once its certificates are
// in the IdentityStore: the address, ATAK's connection flags, and the
// fingerprints of the client identity and truststore. No password or key is
// in it, so it can be stored as plain data (Codable).

import Foundation

public struct ServerConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var description: String
    public var address: ConnectString
    public var enabled: Bool
    public var useAuth: Bool
    public var cacheCredentials: String?
    public var enrollForCertificate: Bool
    public var enrollUseTrust: Bool
    /// The client identity's fingerprint; nil until one is imported or enrolled.
    public var identity: Fingerprint?
    /// The truststore's fingerprint; nil for a plain TCP server.
    public var truststore: Fingerprint?

    public init(id: UUID = UUID(), description: String, address: ConnectString, enabled: Bool = true,
                useAuth: Bool = false, cacheCredentials: String? = nil, enrollForCertificate: Bool = false,
                enrollUseTrust: Bool = true, identity: Fingerprint? = nil, truststore: Fingerprint? = nil) {
        self.id = id
        self.description = description
        self.address = address
        self.enabled = enabled
        self.useAuth = useAuth
        self.cacheCredentials = cacheCredentials
        self.enrollForCertificate = enrollForCertificate
        self.enrollUseTrust = enrollUseTrust
        self.identity = identity
        self.truststore = truststore
    }

    /// The transport commo connects with: TCP as is, SSL and QUIC with the
    /// identity and truststore exported from `store`.
    public func transport(using store: IdentityStore) throws -> CommoTransport {
        guard address.proto != .tcp else { return .tcp }
        guard let truststore else { throw IdentityError("\(description): no truststore for \(address)") }
        guard let identity else {
            throw IdentityError(enrollForCertificate
                ? "\(description): no client certificate yet; this server enrolls for one"
                : "\(description): no client certificate for \(address)")
        }
        let credentials = try store.credentials(identity: identity, truststore: truststore)
        return address.proto == .quic ? .quic(credentials) : .ssl(credentials)
    }
}

extension IdentityStore {
    /// Imports every certificate a data package carries into the store and
    /// returns its servers as configs. A certificate the package gives no
    /// password for is refused: there is nothing to open it with.
    public func importServers(from package: DataPackage) throws -> [ServerConfig] {
        try package.servers.map { server in
            ServerConfig(description: server.description, address: server.address, enabled: server.enabled,
                         useAuth: server.useAuth, cacheCredentials: server.cacheCredentials,
                         enrollForCertificate: server.enrollForCertificate, enrollUseTrust: server.enrollUseTrust,
                         identity: try server.clientCertificate.map { try importIdentity($0) },
                         truststore: try server.truststore.map { try importTruststore($0) })
        }
    }

    private func importIdentity(_ certificate: DataPackage.Certificate) throws -> Fingerprint {
        try importIdentity(pkcs12: certificate.pkcs12, password: try Self.password(of: certificate))
    }

    private func importTruststore(_ certificate: DataPackage.Certificate) throws -> Fingerprint {
        try importTruststore(pkcs12: certificate.pkcs12, password: try Self.password(of: certificate))
    }

    private static func password(of certificate: DataPackage.Certificate) throws -> String {
        guard let password = certificate.password else {
            throw IdentityError("the package gives no password for \(certificate.fileName)")
        }
        return password
    }
}
