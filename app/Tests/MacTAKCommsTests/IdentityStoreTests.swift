// G3.2b's gate leg: a data package's certificates go into a throwaway
// keychain, come back out as commo's credentials, and two clients see each
// other over mutual TLS with them. Plus the store's own rules: a wrong
// password reaches no keychain, a second import is harmless, and nothing
// ever lands in the login keychain.

import Foundation
import XCTest
@testable import MacTAKComms

final class IdentityStoreTests: XCTestCase {
    private var pki: TestPKI?
    private var keychain: TemporaryKeychain?

    override func setUpWithError() throws {
        pki = try TestPKI.make(clients: ["a", "b"])
        keychain = try TemporaryKeychain()
    }

    override func tearDown() {
        keychain?.delete()
        pki?.remove()
        keychain = nil
        pki = nil
    }

    func testTwoClientsConnectWithIdentitiesFromTheKeychain() async throws {
        let pki = try XCTUnwrap(pki), store = try XCTUnwrap(keychain).store
        let port = try freePort()
        let server = try FakeServer.cot(port: port, ["--tls", pki.serverCert, pki.serverKey,
                                                     "--client-ca", pki.caPEM])
        defer { server.stop() }

        var configs: [String: ServerConfig] = [:]
        for client in ["a", "b"] {
            let package = try DataPackage(data: Self.package(pki: pki, client: client, port: port), name: "\(client).zip")
            configs[client] = try XCTUnwrap(store.importServers(from: package).first)
        }
        XCTAssertEqual(try store.identities().count, 2)
        XCTAssertEqual(configs["a"]?.truststore, configs["b"]?.truststore, "one CA, stored once")

        try await TwoClients.roundTrip(port: port) { client in
            let transport = try XCTUnwrap(configs[client]).transport(using: store)
            guard case let .ssl(credentials) = transport else { throw IdentityError("not SSL: \(transport)") }
            XCTAssertNotEqual(credentials.identity, try pki.credentials(client).identity,
                              "the identity comes from the keychain's export, not the package's bytes")
            return transport
        }
        XCTAssertTrue(server.log.contains("tls client CN=a"), server.log)
        XCTAssertTrue(server.log.contains("tls client CN=b"), server.log)
    }

    func testAWrongPasswordReachesNoKeychain() throws {
        let pki = try XCTUnwrap(pki), store = try XCTUnwrap(keychain).store
        let p12 = try pki.credentials("a").identity
        XCTAssertThrowsError(try store.importIdentity(pkcs12: p12, password: "wrong")) {
            XCTAssertTrue("\($0)".hasPrefix("reading the PKCS#12:"), "\($0)")
        }
        XCTAssertThrowsError(try store.importTruststore(pkcs12: try pki.credentials("a").ca, password: "wrong"))
        XCTAssertEqual(try store.identities().count, 0)
    }

    func testImportingTwiceIsHarmlessAndRemoveRemoves() throws {
        let pki = try XCTUnwrap(pki), store = try XCTUnwrap(keychain).store
        let credentials = try pki.credentials("a")
        let first = try store.importIdentity(pkcs12: credentials.identity, password: TestPKI.password)
        let again = try store.importIdentity(pkcs12: credentials.identity, password: TestPKI.password)
        XCTAssertEqual(first, again)
        XCTAssertEqual(try store.identities().map(\.fingerprint), [first])
        XCTAssertEqual(try store.identities().first?.subject, "a")
        let trust = try store.importTruststore(pkcs12: credentials.ca, password: TestPKI.password)
        XCTAssertEqual(try store.importTruststore(pkcs12: credentials.ca, password: TestPKI.password), trust)

        try store.removeIdentity(first)
        XCTAssertEqual(try store.identities().count, 0)
        XCTAssertThrowsError(try store.credentials(identity: first, truststore: trust)) {
            XCTAssertEqual("\($0)", "no identity \(first) in the keychain")
        }
        try store.removeTruststore(trust)
    }

    /// A certificate-only PKCS#12 is a truststore, not an identity.
    func testATruststoreIsNotAnIdentity() throws {
        let pki = try XCTUnwrap(pki), store = try XCTUnwrap(keychain).store
        XCTAssertThrowsError(try store.importIdentity(pkcs12: try pki.credentials("a").ca, password: TestPKI.password)) {
            XCTAssertEqual("\($0)", "the PKCS#12 carries no private key, so it is not a client identity")
        }
    }

    /// The tests' imports stay in the throwaway keychain: the login
    /// keychain's search list never sees them (an early probe's
    /// SecPKCS12Import without a keychain put a CA into the login keychain).
    func testNothingReachesTheLoginKeychain() throws {
        let pki = try XCTUnwrap(pki), store = try XCTUnwrap(keychain).store
        let mine = try store.importIdentity(pkcs12: try pki.credentials("b").identity, password: TestPKI.password)
        // A runner with no default keychain has nothing to leak into.
        let login = (try? IdentityStore.login.identities()) ?? []
        XCTAssertFalse(login.contains { $0.fingerprint == mine })
    }

    /// A data package as a TAK server hands one out: a .pref naming the
    /// truststore and the client's certificate, and the two .p12 files.
    static func package(pki: TestPKI, client: String, port: Int, callsign: String? = nil) throws -> Data {
        let credentials = try pki.credentials(client)
        var zip = ZipWriter()
        zip.add("MANIFEST/manifest.xml", "<MissionPackageManifest version='2'/>")
        zip.add("\(client)/server.pref", ImportParsingTests.pref(streams: [[
            "connectString": "127.0.0.1:\(port):ssl", "description": "fake", "enabled": "true",
            "caLocation": "cert/truststore.p12", "caPassword": TestPKI.password,
            "certificateLocation": "cert/\(client).p12", "clientPassword": TestPKI.password,
        ]], app: callsign.map { ["locationCallsign": $0] } ?? [:]))
        zip.add("\(client)/truststore.p12", credentials.ca)
        zip.add("\(client)/\(client).p12", credentials.identity)
        return zip.archive()
    }
}
