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
// Not yet (dev/g3/NOTES.md §G3.2c): ATAK's "quick connect", enrollment
// with no truststore trusting the system's public CAs. commo takes CAs only
// as PKCS#12, and the Keychain can't export certificates alone in that
// form, so a server without a truststore is refused.

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
        guard let trust = server.truststore else {
            throw IdentityError("\(server.description): enrollment needs the server's truststore "
                                + "(enrolling against public CAs isn't supported yet)")
        }
        let enrolled = try await client.enroll(host: server.address.host, port: port, user: user,
                                               password: password, useToken: useToken,
                                               ca: try truststore(trust), timeout: timeout)
        var result = server
        result.identity = try importIdentity(pkcs12: enrolled.identity, password: enrolled.identityPassword)
        if let returned = enrolled.truststore {
            result.truststore = try importTruststore(pkcs12: returned, password: enrolled.truststorePassword)
        }
        let profile = try await deviceProfile(host: server.address.host, port: port, clientUid: client.uid,
                                              user: user, password: password, truststore: trust)
        return EnrollmentResult(server: result, profile: profile)
    }

    /// The device profile for `clientUid`, or nil when the server has none.
    func deviceProfile(host: String, port: Int, clientUid: String, user: String, password: String,
                       truststore: Fingerprint) async throws -> DataPackage? {
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.port = port
        url.path = "/Marti/api/tls/profile/enrollment"
        url.queryItems = [URLQueryItem(name: "clientUid", value: clientUid)]
        guard let address = url.url else { throw IdentityError("no profile URL for \(host)") }
        let response = try await TakHTTPS.get(address, user: user, password: password,
                                              caPEM: try truststorePEM(truststore), verifyHost: false)
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
