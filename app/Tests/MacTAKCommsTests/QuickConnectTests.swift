// G3.2e: ATAK's Quick Connect, enrollment against the public CAs. The
// tests' CA stands in for the system's roots, and the fake enrollment server
// serves a leaf that names 127.0.0.1, as a public CA's certificate names its
// server. The gate: a quick connect through ServerConnections adds the
// server with an identity and the CA it sent, and fetches the profile with
// the name checked. The refusals: a server whose certificate doesn't name
// it, one no public CA signed, and one that sends no CA. And the system's
// real roots make a truststore commo reads.

import Foundation
import XCTest
@testable import MacTAKComms

@MainActor
final class QuickConnectTests: XCTestCase {
    private var pki: TestPKI?
    private var keychain: TemporaryKeychain?
    private static let password = "enroll-pass"

    override func setUp() async throws {
        let pki = try TestPKI.make(clients: [])
        self.pki = pki
        let publicCA = try pki.caDER()
        keychain = try TemporaryKeychain(publicRoots: { [publicCA] })
    }

    override func tearDown() async throws {
        keychain?.delete()
        pki?.remove()
    }

    func testAQuickConnectAddsTheServerWithItsCA() async throws {
        let pki = try XCTUnwrap(pki), store = try XCTUnwrap(keychain).store
        let profile = try EnrollmentTests.profile(callsign: "QUICK-1")
        defer { try? FileManager.default.removeItem(at: profile) }
        let port = try freePort()
        let server = try FakeServer.enroll(port: port, pki: pki, user: "alice", password: Self.password, named: true,
                                           ["--profile", profile.path])
        defer { server.stop() }
        let settings = MemorySettings()
        let connections = ServerConnections(settings: settings, identities: store, me: .testing(settings))

        let added = try await connections.quickConnect(address: " 127.0.0.1 ", user: "alice", password: Self.password,
                                                       enrollmentPort: port)

        XCTAssertEqual(connections.servers.map(\.id), [added.id])
        XCTAssertEqual(added.description, "127.0.0.1")
        XCTAssertEqual(added.address, ConnectString(host: "127.0.0.1", port: 8089, proto: .ssl))
        XCTAssertTrue(added.enabled)
        XCTAssertFalse(added.enrollUseTrust)
        XCTAssertNotNil(added.identity)
        let sentCA = try store.importTruststore(pkcs12: try pki.truststore().pkcs12, password: TestPKI.password)
        XCTAssertEqual(added.truststore, sentCA, "the CA the server sent became its truststore")
        XCTAssertNoThrow(try added.transport(using: store))
        XCTAssertEqual(connections.callsign, "QUICK-1", "the profile came, over a name-checked GET")
        XCTAssertTrue(server.log.contains("signed subject=CN=alice"), server.log)
    }

    func testAFailedQuickConnectKeepsNoServer() async throws {
        let store = try XCTUnwrap(keychain).store
        let connections = ServerConnections(settings: MemorySettings(), identities: store, me: .testing(MemorySettings()))
        do {
            try await connections.quickConnect(address: "127.0.0.1", user: "alice", password: Self.password,
                                               enrollmentPort: try freePort())
            XCTFail("a quick connect with no server enrolled")
        } catch {}
        XCTAssertTrue(connections.servers.isEmpty)
        XCTAssertEqual(try store.identities().count, 0)
    }

    /// A public CA vouches for a name: a certificate for another name is
    /// refused before any request, where the server's own truststore
    /// skips the check.
    func testAQuickConnectChecksTheServersName() async throws {
        let pki = try XCTUnwrap(pki), store = try XCTUnwrap(keychain).store
        let port = try freePort()
        let server = try FakeServer.enroll(port: port, pki: pki, user: "alice", password: Self.password)
        defer { server.stop() }
        try await assertRefused(quickServer(), store: store, port: port, server: server,
                                status: "untrusted server certificate")
    }

    func testAQuickConnectRefusesAServerNoPublicCASigned() async throws {
        let pki = try XCTUnwrap(pki)
        let otherCA = try pki.caDER(other: true)
        let keychain = try TemporaryKeychain(publicRoots: { [otherCA] })
        defer { keychain.delete() }
        let port = try freePort()
        let server = try FakeServer.enroll(port: port, pki: pki, user: "alice", password: Self.password, named: true)
        defer { server.stop() }
        try await assertRefused(quickServer(), store: keychain.store, port: port, server: server,
                                status: "untrusted server certificate")
    }

    /// ATAK: "Server did not return trust configuration". Without the CA
    /// nothing could connect afterwards, so nothing is kept.
    func testAQuickConnectNeedsTheServersCA() async throws {
        let pki = try XCTUnwrap(pki), store = try XCTUnwrap(keychain).store
        let port = try freePort()
        let server = try FakeServer.enroll(port: port, pki: pki, user: "alice", password: Self.password, named: true,
                                           ["--no-ca"])
        defer { server.stop() }
        let commo = try CommoClient(uid: "g3-quick-noca", callsign: "NOCA")
        do {
            _ = try await store.enroll(quickServer(), user: "alice", password: Self.password,
                                       using: commo, port: port)
            XCTFail("a quick connect kept a server that sent no CA")
        } catch let error as IdentityError {
            XCTAssertEqual(error.description,
                           "quick: the server sent no CA certificates, which a quick connect needs to trust it")
        }
        await commo.shutdown()
        XCTAssertEqual(try store.identities().count, 0, "no identity kept")
        XCTAssertTrue(server.log.contains("signed subject=CN=alice"), "the refusal came after signing:\n\(server.log)")
    }

    /// The real roots: commo reads the PKCS#12 they make (a bad one fails
    /// as "invalid CA certificate") and refuses the test CA's server.
    func testTheSystemRootsMakeATruststoreCommoReads() async throws {
        let roots = try IdentityStore.systemRoots()
        XCTAssertGreaterThan(roots.count, 50, "the system's roots")
        let truststore = try TLSTruststore(certificates: roots)
        let pki = try XCTUnwrap(pki)
        let port = try freePort()
        let server = try FakeServer.enroll(port: port, pki: pki, user: "alice", password: Self.password, named: true)
        defer { server.stop() }
        let commo = try CommoClient(uid: "g3-quick-system", callsign: "SYSTEM")
        do {
            _ = try await commo.enroll(host: "127.0.0.1", port: port, user: "alice", password: Self.password,
                                       ca: truststore, verifyHost: true, keyBits: 2048)
            XCTFail("the system's roots trusted the test CA")
        } catch let error as EnrollmentError {
            XCTAssertEqual(error.status, "untrusted server certificate")
        }
        await commo.shutdown()
        XCTAssertFalse(server.log.contains(" -> "), "a request reached the server:\n\(server.log)")
    }

    func testTheAddressParsesAsATAKsDialogTakesIt() throws {
        let cases: [(String, ConnectString)] = [
            ("tak.example.org", ConnectString(host: "tak.example.org", port: 8089, proto: .ssl)),
            ("https://tak.example.org:8443/", ConnectString(host: "tak.example.org", port: 8443, proto: .ssl)),
            ("tak.example.org:8090:quic", ConnectString(host: "tak.example.org", port: 8090, proto: .quic)),
            ("tak.example.org:8087:tcp", ConnectString(host: "tak.example.org", port: 8087, proto: .ssl)),
            ("[::1]", ConnectString(host: "::1", port: 8089, proto: .ssl)),
            ("[::1]:9000", ConnectString(host: "::1", port: 9000, proto: .ssl)),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(try ConnectString(quickConnect: text), expected, text)
        }
        XCTAssertThrowsError(try ConnectString(quickConnect: "  "))
        XCTAssertThrowsError(try ConnectString(quickConnect: "tak.example.org:0"))
    }

    // MARK: -

    private func quickServer() -> ServerConfig {
        ServerConfig(description: "quick", address: ConnectString(host: "127.0.0.1", port: 8089, proto: .ssl),
                     enrollForCertificate: true, enrollUseTrust: false)
    }

    private func assertRefused(_ server: ServerConfig, store: IdentityStore, port: Int, server fake: FakeServer,
                               status: String) async throws {
        let commo = try CommoClient(uid: "g3-quick-refused", callsign: "REFUSED")
        do {
            _ = try await store.enroll(server, user: "alice", password: Self.password, using: commo, port: port)
            XCTFail("enrolled with a server a quick connect must refuse")
        } catch let error as EnrollmentError {
            XCTAssertEqual(error.status, status)
        }
        await commo.shutdown()
        XCTAssertFalse(fake.log.contains(" -> "), "a request reached the server:\n\(fake.log)")
        XCTAssertEqual(try store.identities().count, 0)
    }
}
