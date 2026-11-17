// G3.2's TLS and QUIC legs: the round trip (Support/TwoClients.swift) over
// TLS with client certificates, the way a TAK server's port 8089 runs, and
// over QUIC (ALPN "takstream"), with a throwaway PKI (Support/TestPKI.swift).

import Foundation
import XCTest
@testable import MacTAKComms

final class SecureTransportTests: XCTestCase {
    private var pki: TestPKI?

    override func setUpWithError() throws {
        pki = try TestPKI.make(clients: ["a", "b"])
    }

    override func tearDown() {
        pki?.remove()
        pki = nil
    }

    /// Two clients with certificates from the server's CA see each other
    /// through a server that requires one, and it sees who they are.
    func testTwoClientsOverMutualTLS() async throws {
        let pki = try XCTUnwrap(pki)
        let port = try freePort()
        let server = try FakeServer.cot(port: port, ["--tls", pki.serverCert, pki.serverKey,
                                                     "--client-ca", pki.caPEM])
        defer { server.stop() }
        try await TwoClients.roundTrip(port: port) { .ssl(try pki.credentials($0)) }
        XCTAssertTrue(server.log.contains("tls client CN=a"), server.log)
        XCTAssertTrue(server.log.contains("tls client CN=b"), server.log)
    }

    /// A client whose certificate comes from another CA is refused: the
    /// server fails its handshake, and nothing it sends reaches a client
    /// that did connect.
    func testServerRefusesAClientFromAnotherCA() async throws {
        let pki = try XCTUnwrap(pki)
        let port = try freePort()
        let server = try FakeServer.cot(port: port, ["--tls", pki.serverCert, pki.serverKey,
                                                     "--client-ca", pki.caPEM])
        defer { server.stop() }

        let a = try TwoClients.Client(uid: "g3-tls-a-\(UUID().uuidString.prefix(8))")
        try await a.commo.connect(host: "127.0.0.1", port: port, transport: .ssl(try pki.credentials("a")))
        try await a.seen.wait("A's interface up", timeout: 15, TwoClients.isInterfaceUp)

        let impostor = try TwoClients.Client(uid: "g3-tls-impostor-\(UUID().uuidString.prefix(8))")
        await impostor.commo.startBeacon(every: .seconds(1))
        try await impostor.commo.connect(host: "127.0.0.1", port: port,
                                         transport: .ssl(try pki.credentials("impostor")))
        try server.waitFor("tls handshake failed", timeout: 15)
        let markerUid = "g3-tls-impostor-marker"
        try? await impostor.commo.broadcast(TwoClients.marker(uid: markerUid))
        try await a.seen.never("A got the impostor's marker", within: 3) { TwoClients.isCot($0, uid: markerUid) }
        XCTAssertFalse(server.log.contains("tls client CN=impostor"), server.log)

        await impostor.close()
        await a.close()
    }

    /// Two clients see each other over QUIC through fake-quic-server.py.
    /// Its python is the aioquic venv's (dev/g1/headless/test/quic-venv.sh),
    /// which `make test-app` passes in MACTAK_QUIC_PYTHON.
    func testTwoClientsOverQUIC() async throws {
        let pki = try XCTUnwrap(pki)
        let python = try Self.quicPython()
        let port = try freePort(SOCK_DGRAM)
        let server = try FakeServer.quic(python: python, port: port, cert: pki.serverCert, key: pki.serverKey)
        defer { server.stop() }
        try await TwoClients.roundTrip(port: port) { .quic(try pki.credentials($0)) }
        XCTAssertTrue(server.log.contains("handshake alpn=takstream"), server.log)
    }

    /// The venv's python, or a skip when the test runs outside `make
    /// test-app`; MACTAK_REQUIRE_ALL_LEGS (set by make) turns the skip into a
    /// failure, so CI can't pass without the leg.
    private static func quicPython() throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let python = env["MACTAK_QUIC_PYTHON"], !python.isEmpty { return python }
        let why = "MACTAK_QUIC_PYTHON is not set — run `make test-app`, or set it to dev/g1/headless/test/quic-venv.sh's output"
        if env["MACTAK_REQUIRE_ALL_LEGS"] != nil { throw CommoError(description: why) }
        throw XCTSkip(why)
    }
}
