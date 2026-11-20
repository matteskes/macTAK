// ServerEnrollment.swift — a server's enrollment, as ATAK 5.5 runs it (G3.2c).
//
// CertificateEnrollmentClient, read at the pin: enroll on port 8446 with
// the server's truststore, keep the new client certificate, and keep the
// CAs the server returned as the server's truststore. Then
// DeviceProfileOperation fetches /Marti/api/tls/profile/enrollment
// ?clientUid=<uid> on the same port with the same basic auth: a data
// package of preferences, or nothing (204 or 404) when the server has no
// profile for this user.
//
// Quick connect (G3.2e) is ATAK's enrollment with enrollUseTrust off, as
// the Quick Connect dialog adds a server: no truststore of the server's own,
// so CertificateEnrollmentClient trusts the public CAs instead (its local
// trust manager's issuers), checks the server's name, and requires the
// server to send its CAs, which become the server's truststore. The device
// profile is fetched with the name check on too. Here the public CAs are the
// system's roots (IdentityStore.publicRoots), handed to commo as a PKCS#12
// built by its own OpenSSL.

import Foundation

public struct EnrollmentResult: Sendable {
    /// The server, now with its enrolled identity and, if the server sent
    /// CAs, their truststore.
    public var server: ServerConfig
    /// The device profile, when the server has one for this user.
    public var profile: DataPackage?
}

extension IdentityStore {
    /// Enrolls `server` for a client certificate as `user`, keeps the
    /// result in the store, and fetches the device profile.
    public func enroll(_ server: ServerConfig, user: String, password: String, useToken: Bool = false,
                       using client: CommoClient, port: Int = CommoClient.enrollmentPort,
                       timeout: Duration = .seconds(120)) async throws -> EnrollmentResult {
        let trust = try enrollmentTrust(for: server)
        let enrolled = try await client.enroll(host: server.address.host, port: port, user: user,
                                               password: password, useToken: useToken, ca: trust.truststore,
                                               verifyHost: trust.verifyHost, timeout: timeout)
        var returned: Fingerprint?
        if let ca = enrolled.truststore {
            returned = try importTruststore(pkcs12: ca, password: enrolled.truststorePassword)
        } else if trust.verifyHost {
            // ATAK: "Server did not return trust configuration". Without the
            // CAs nothing could connect to the server, so keep nothing.
            throw IdentityError("\(server.description): the server sent no CA certificates, "
                                + "which a quick connect needs to trust it")
        }
        var result = server
        result.identity = try importIdentity(pkcs12: enrolled.identity, password: enrolled.identityPassword)
        if let returned { result.truststore = returned }
        var profileTrust = trust.pem
        if trust.verifyHost, let returned { profileTrust += try truststorePEM(returned) }
        let profile = try await deviceProfile(host: server.address.host, port: port, clientUid: client.uid,
                                              user: user, password: password, caPEM: profileTrust,
                                              verifyHost: trust.verifyHost)
        return EnrollmentResult(server: result, profile: profile)
    }

    /// What an enrollment trusts: the server's own truststore, as configured,
    /// with no name check (servers are often reached by an address their
    /// certificate doesn't name); or, for a quick connect, the public CAs
    /// with the name checked.
    private func enrollmentTrust(for server: ServerConfig) throws
        -> (truststore: TLSTruststore, pem: Data, verifyHost: Bool) {
        if !server.enrollUseTrust {
            let roots = try publicRoots()
            return (try TLSTruststore(certificates: roots), Self.pem(roots), true)
        }
        guard let fingerprint = server.truststore else {
            throw IdentityError("\(server.description): enrollment needs the server's truststore; import it "
                                + "(Certificates…), or turn off Enroll with Preconfigured Trust to trust public CAs")
        }
        return (try truststore(fingerprint), try truststorePEM(fingerprint), false)
    }

    /// The device profile for `clientUid`, or nil when the server has none.
    func deviceProfile(host: String, port: Int, clientUid: String, user: String, password: String,
                       caPEM: Data, verifyHost: Bool) async throws -> DataPackage? {
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.port = port
        url.path = "/Marti/api/tls/profile/enrollment"
        url.queryItems = [URLQueryItem(name: "clientUid", value: clientUid)]
        guard let address = url.url else { throw IdentityError("no profile URL for \(host)") }
        let response = try await TakHTTPS.get(address, user: user, password: password,
                                              caPEM: caPEM, verifyHost: verifyHost)
        switch response.status {
        case 200 where !response.body.isEmpty:
            return try DataPackage(data: response.body, name: "the device profile", requireServer: false)
        case 200, 204, 404:
            return nil
        default:
            throw IdentityError("the device profile request answered HTTP \(response.status)")
        }
    }
}
