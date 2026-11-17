// G3.2c's legs: certificate enrollment through commo against
// dev/g3/test/fake-enroll-server.py, and the device profile through the
// shim's curl. The gate: two clients enroll for certificates, then see each
// other over mutual TLS with them. The refusals: a wrong password, a server
// from another CA (enrollment and the https GET both refuse it before any
// request), and a non-https URL.

import Foundation
import XCTest
@testable import MacTAKComms

final class EnrollmentTests: XCTestCase {
    private var pki: TestPKI?
    private var keychain: TemporaryKeychain?
    private static let password = "enroll-pass"

    override func setUpWithError() throws {
        pki = try TestPKI.make(clients: [])
        keychain = try TemporaryKeychain()
    }

    override func tearDown() {
        keychain?.delete()
        pki?.remove()
        keychain = nil
        pki = nil
    }

    func testEnrolledClientsSeeEachOtherOverMutualTLS() async throws {
        let pki = try XCTUnwrap(pki), store = try XCTUnwrap(keychain).store
        let profile = try Self.profile(callsign: "ENROLLED-1")
        defer { try? FileManager.default.removeItem(at: profile) }
        let enrollPort = try freePort(), cotPort = try freePort()
        let enrollServer = try FakeServer.enroll(port: enrollPort, pki: pki, user: "alice,bob",
                                                 password: Self.password, ["--profile", profile.path])
        defer { enrollServer.stop() }
        let cotServer = try FakeServer.cot(port: cotPort, ["--tls", pki.serverCert, pki.serverKey,
                                                           "--client-ca", pki.caPEM])
        defer { cotServer.stop() }

        let trust = try store.importTruststore(pkcs12: try pki.truststore().pkcs12, password: TestPKI.password)
        let server = ServerConfig(description: "fake", address: ConnectString(host: "127.0.0.1", port: cotPort, proto: .ssl),
                                  enrollForCertificate: true, truststore: trust)
        XCTAssertThrowsError(try server.transport(using: store)) {
            XCTAssertEqual("\($0)", "fake: no client certificate yet; this server enrolls for one")
        }

        var enrolled: [String: ServerConfig] = [:]
        for (client, user) in [("a", "alice"), ("b", "bob")] {
            let commo = try CommoClient(uid: "g3-enroll-\(user)", callsign: user.uppercased())
            let result = try await store.enroll(server, user: user, password: Self.password, using: commo, port: enrollPort)
            await commo.shutdown()
            XCTAssertNotNil(result.server.identity)
            XCTAssertEqual(result.server.truststore, trust, "the server's CA came back: the same truststore")
            XCTAssertEqual(result.profile?.callsign, "ENROLLED-1")
            enrolled[client] = result.server
        }
        XCTAssertEqual(try store.identities().map(\.subject).sorted(), ["alice", "bob"])
        XCTAssertTrue(enrollServer.log.contains("signed subject=CN=alice, O=macTAK test, OU=fake enrollment"),
                      enrollServer.log)
        XCTAssertTrue(enrollServer.log.contains("profile for clientUid=g3-enroll-bob"), enrollServer.log)

        try await TwoClients.roundTrip(port: cotPort) { try XCTUnwrap(enrolled[$0]).transport(using: store) }
        XCTAssertTrue(cotServer.log.contains("tls client CN=alice"), cotServer.log)
        XCTAssertTrue(cotServer.log.contains("tls client CN=bob"), cotServer.log)
    }

    func testAWrongPasswordFailsTheConfigRequest() async throws {
        let pki = try XCTUnwrap(pki)
        let port = try freePort()
        let server = try FakeServer.enroll(port: port, pki: pki, user: "alice", password: Self.password)
        defer { server.stop() }
        let commo = try CommoClient(uid: "g3-enroll-wrong", callsign: "WRONG")
        do {
            _ = try await commo.enroll(host: "127.0.0.1", port: port, user: "alice", password: "wrong",
                                       ca: try pki.truststore(), keyBits: 2048)
            XCTFail("enrolled with a wrong password")
        } catch let error as EnrollmentError {
            XCTAssertEqual(error.step, "the certificate config request")
            XCTAssertEqual(error.status, "authentication failed")
        }
        await commo.shutdown()
        XCTAssertTrue(server.log.contains("GET /Marti/api/tls/config -> 401"), server.log)
    }

    /// An indented signing reply enrolls. Unpatched commo read the
    /// whitespace between the elements as a certificate and crashed with
    /// SIGSEGV (trap 8, commo patch 0009).
    func testAnIndentedReplyEnrolls() async throws {
        let pki = try XCTUnwrap(pki)
        let port = try freePort()
        let server = try FakeServer.enroll(port: port, pki: pki, user: "alice", password: Self.password,
                                           ["--reply-shape", "indented"])
        defer { server.stop() }
        let commo = try CommoClient(uid: "g3-enroll-indented", callsign: "INDENTED")
        let enrolled = try await commo.enroll(host: "127.0.0.1", port: port, user: "alice", password: Self.password,
                                              ca: try pki.truststore(), keyBits: 2048)
        await commo.shutdown()
        XCTAssertFalse(enrolled.identity.isEmpty)
        XCTAssertNotNil(enrolled.truststore, "the reply's CA came through")
    }

    /// An empty certificate element fails the enrollment with a reason,
    /// where unpatched commo crashed.
    func testAnEmptyCertificateFailsTheSigning() async throws {
        let pki = try XCTUnwrap(pki)
        let port = try freePort()
        let server = try FakeServer.enroll(port: port, pki: pki, user: "alice", password: Self.password,
                                           ["--reply-shape", "empty-ca"])
        defer { server.stop() }
        let commo = try CommoClient(uid: "g3-enroll-empty", callsign: "EMPTY")
        do {
            _ = try await commo.enroll(host: "127.0.0.1", port: port, user: "alice", password: Self.password,
                                       ca: try pki.truststore(), keyBits: 2048)
            XCTFail("enrolled with an empty CA in the reply")
        } catch let error as EnrollmentError {
            XCTAssertEqual(error.step, "signing")
        }
        await commo.shutdown()
    }

    /// A server whose certificate doesn't chain to the truststore gets no
    /// request: not the enrollment's, not the profile's.
    func testAServerFromAnotherCAIsRefused() async throws {
        let pki = try XCTUnwrap(pki)
        let port = try freePort()
        let server = try FakeServer.enroll(port: port, pki: pki, user: "alice", password: Self.password)
        defer { server.stop() }
        let commo = try CommoClient(uid: "g3-enroll-untrusted", callsign: "UNTRUSTED")
        do {
            _ = try await commo.enroll(host: "127.0.0.1", port: port, user: "alice", password: Self.password,
                                       ca: try pki.truststore(other: true), keyBits: 2048)
            XCTFail("enrolled with an untrusted server")
        } catch let error as EnrollmentError {
            XCTAssertEqual(error.status, "untrusted server certificate")
        }
        await commo.shutdown()

        let otherCA = try Data(contentsOf: pki.dir.appendingPathComponent("other-ca.crt"))
        let url = try XCTUnwrap(URL(string: "https://127.0.0.1:\(port)/Marti/api/tls/profile/enrollment?clientUid=x"))
        do {
            _ = try await TakHTTPS.get(url, user: "alice", password: Self.password, caPEM: otherCA, verifyHost: false)
            XCTFail("fetched from an untrusted server")
        } catch let error as CommoError {
            XCTAssertTrue(error.description.contains("CURLcode 60"), error.description)   // CURLE_PEER_FAILED_VERIFICATION
        }
        XCTAssertFalse(server.log.contains(" -> "), "a request reached the server:\n\(server.log)")
    }

    func testTheHTTPSGetTrustsItsCAAndNothingElse() async throws {
        let pki = try XCTUnwrap(pki)
        let port = try freePort()
        let server = try FakeServer.enroll(port: port, pki: pki, user: "alice", password: Self.password)
        defer { server.stop() }
        let ca = try Data(contentsOf: URL(fileURLWithPath: pki.caPEM))
        let profile = try XCTUnwrap(URL(string: "https://127.0.0.1:\(port)/Marti/api/tls/profile/enrollment?clientUid=x"))

        let anonymous = try await TakHTTPS.get(profile, caPEM: ca, verifyHost: false)
        XCTAssertEqual(anonymous.status, 401)
        let none = try await TakHTTPS.get(profile, user: "alice", password: Self.password, caPEM: ca, verifyHost: false)
        XCTAssertEqual(none.status, 204, "no --profile: no content")
        // The server's certificate names no host, so a name check refuses it.
        do {
            _ = try await TakHTTPS.get(profile, user: "alice", password: Self.password, caPEM: ca, verifyHost: true)
            XCTFail("a certificate without the host's name passed the name check")
        } catch let error as CommoError {
            XCTAssertTrue(error.description.contains("CURLcode 60"), error.description)
        }
        let plain = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/Marti/api/tls/config"))
        do {
            _ = try await TakHTTPS.get(plain, caPEM: ca, verifyHost: false)
            XCTFail("an http URL was fetched")
        } catch let error as CommoError {
            XCTAssertTrue(error.description.contains("CURLcode 1)"), error.description)   // CURLE_UNSUPPORTED_PROTOCOL
        }
    }

    /// A device profile as a TAK server sends one: a data package of
    /// preferences with no server connection.
    private static func profile(callsign: String) throws -> URL {
        var zip = ZipWriter()
        zip.add("MANIFEST/manifest.xml", "<MissionPackageManifest version='2'/>")
        zip.add("profile/enrollment.pref", ImportParsingTests.pref(streams: [], app: ["locationCallsign": callsign]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mactak-profile-\(UUID().uuidString.prefix(8)).zip")
        try zip.archive().write(to: url)
        return url
    }
}
