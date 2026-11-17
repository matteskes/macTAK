// Enrollment.swift — certificate enrollment through commo, and the one
// https GET it needs (G3.2c).
//
// TAK Server users usually get a client certificate by username and
// password. commo runs the protocol (core/impl/enrollmentmanager.cpp):
// generate a key, GET /Marti/api/tls/config for the certificate's name
// entries, POST the CSR to /Marti/api/tls/signClient/v2, and package the
// signed certificate with the key as PKCS#12. ATAK then fetches a device
// profile, which commo has no call for: TakHTTPS.get makes that request with
// the curl and OpenSSL 3 commo carries, so every TAK connection stays on one
// TLS stack (dev/g3/NOTES.md §G3.2).

import CCommoShim
import Foundation

/// What a successful enrollment hands back: the new client identity, and
/// the CAs the server sent with it (nil when it sent none), as PKCS#12.
public struct EnrolledIdentity: Sendable {
    public let identity: Data
    public let identityPassword: String
    public let truststore: Data?
    public let truststorePassword: String
}

/// An enrollment that failed, at which step and how (commo's
/// SimpleFileIOStatus, by name).
public struct EnrollmentError: Error, CustomStringConvertible, Equatable {
    public let step: String
    public let status: String
    public let info: String

    public var description: String {
        "enrollment failed at \(step): \(status)" + (info.isEmpty ? "" : " (\(info))")
    }
}

/// One update from commo's EnrollmentIO, as the shim forwards it.
struct EnrollmentUpdate {
    let step: Int32
    let status: Int32
    let info: String

    static let steps = ["key generation", "the certificate config request", "signing"]
    /// commo's SimpleFileIOStatus, in its order (simplefileio.h).
    static let statuses = ["in progress", "success", "host resolution failed", "connection failed",
                           "invalid URL", "unsupported URL", "no such resource", "local file open failed",
                           "local I/O error", "untrusted server certificate", "other TLS error",
                           "authentication failed", "access denied", "timed out", "other error"]
    private static let inProgress: Int32 = 0, success: Int32 = 1, signing: Int32 = 2

    /// nil while the enrollment goes on; its result once it ends. Passwords
    /// are filled in by the caller, which chose them.
    func outcome(identity: Data?, ca: Data?) -> Result<EnrolledIdentity, Error>? {
        if status == Self.inProgress || (status == Self.success && step != Self.signing) { return nil }
        guard status == Self.success, let identity else {
            return .failure(EnrollmentError(step: Self.name(step, in: Self.steps), status: Self.name(status, in: Self.statuses),
                                            info: status == Self.success ? "no identity in the reply" : info))
        }
        return .success(EnrolledIdentity(identity: identity, identityPassword: "", truststore: ca, truststorePassword: ""))
    }

    private static func name(_ value: Int32, in names: [String]) -> String {
        names.indices.contains(Int(value)) ? names[Int(value)] : "code \(value)"
    }
}

extension CommoClient {
    /// ATAK's enrollment port (SslNetCotPort's CERT_ENROLLMENT), which also
    /// serves the device profile.
    public static let enrollmentPort = 8446

    /// Enrolls with the TAK server at host:port for a client certificate,
    /// as `user`. `ca` is the truststore the server must chain to: required,
    /// since commo with no CA trusts any server (#146). verifyHost follows
    /// ATAK: off when the CA is the server's own (a package's truststore),
    /// as servers are often reached by an address their certificate doesn't
    /// name.
    public func enroll(host: String, port: Int = CommoClient.enrollmentPort, user: String, password: String,
                       useToken: Bool = false, ca: TLSTruststore, verifyHost: Bool = false,
                       version: String = "macTAK", keyBits: Int = 4096,
                       timeout: Duration = .seconds(120)) async throws -> EnrolledIdentity {
        let commo = try live()
        let identityPassword = try TLSTruststore.randomPassword()
        let trustPassword = try TLSTruststore.randomPassword()
        let keyPassword = try TLSTruststore.randomPassword()
        var id: Int32 = 0
        try ca.pkcs12.withUnsafeBytes { caBytes in
            try CommoClient.check { err, len in
                mactak_commo_enroll_init(commo, host, Int32(port), verifyHost ? 1 : 0, user, password,
                                         useToken ? 1 : 0, caBytes.bindMemory(to: UInt8.self).baseAddress,
                                         caBytes.count, ca.password, identityPassword, trustPassword,
                                         keyPassword, Int32(keyBits), version, &id, err, len)
            }
        }
        let sink = self.sink
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            sink.endEnrollment(id, .failure(EnrollmentError(step: "the whole enrollment", status: "timed out",
                                                            info: "no result in \(timeout)")))
        }
        defer { watchdog.cancel() }
        let enrolled = try await sink.awaitEnrollment(id) {
            try CommoClient.check { err, len in mactak_commo_enroll_start(commo, id, err, len) }
        }
        return EnrolledIdentity(identity: enrolled.identity, identityPassword: identityPassword,
                                truststore: enrolled.truststore, truststorePassword: trustPassword)
    }
}

/// A truststore as commo takes it: PKCS#12 bytes and their password.
public struct TLSTruststore: Sendable {
    public let pkcs12: Data
    public let password: String

    public init(pkcs12: Data, password: String) {
        self.pkcs12 = pkcs12
        self.password = password
    }

    static func randomPassword() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw CommoError(description: "generating a password failed (\(status))") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// HTTPS to a TAK server through commo's curl and OpenSSL 3, never Apple's
/// TLS (dev/g3/NOTES.md §G3.2).
public enum TakHTTPS {
    public struct Response: Sendable {
        public let status: Int
        public let body: Data
    }

    /// GETs `url` trusting only the PEM certificates in `caPEM`, with basic
    /// auth when `user` is given; https only, no redirects, at most
    /// `maxBytes` of body.
    public static func get(_ url: URL, user: String? = nil, password: String? = nil, caPEM: Data,
                           verifyHost: Bool, maxBytes: Int = 64 << 20,
                           timeoutSeconds: Int = 60) async throws -> Response {
        try CommoClient.initLibraries()
        return try await Task.detached {   // curl blocks: keep it off the caller's executor
            var status = 0
            var body: UnsafeMutablePointer<UInt8>?
            var count = 0
            try caPEM.withUnsafeBytes { ca in
                try CommoClient.check { err, len in
                    mactak_commo_https_get(url.absoluteString, user, password,
                                           ca.bindMemory(to: UInt8.self).baseAddress, ca.count,
                                           verifyHost ? 1 : 0, maxBytes, timeoutSeconds,
                                           &status, &body, &count, err, len)
                }
            }
            defer { mactak_commo_free(body) }
            return Response(status: status, body: body.map { Data(bytes: $0, count: count) } ?? Data())
        }.value
    }
}
