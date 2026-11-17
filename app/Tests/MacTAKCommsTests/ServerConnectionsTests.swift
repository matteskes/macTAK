// G3.2d: the model under the app's servers pane. A data package imported
// through it connects over mutual TLS and shows as connected; the list, the
// client's uid and the package's callsign persist; disabling a server
// disconnects it; a refused connection shows commo's reason.

import Foundation
import XCTest
@testable import MacTAKComms

@MainActor
final class ServerConnectionsTests: XCTestCase {
    private var pki: TestPKI?
    private var keychain: TemporaryKeychain?

    override func setUp() async throws {
        pki = try TestPKI.make(clients: ["a"])
        keychain = try TemporaryKeychain()
    }

    override func tearDown() async throws {
        keychain?.delete()
        pki?.remove()
    }

    func testAnImportedPackageConnectsAndPersists() async throws {
        let pki = try XCTUnwrap(pki), store = try XCTUnwrap(keychain).store
        let port = try freePort()
        let server = try FakeServer.cot(port: port, ["--tls", pki.serverCert, pki.serverKey, "--client-ca", pki.caPEM])
        defer { server.stop() }
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("mactak-\(UUID().uuidString.prefix(8)).zip")
        try IdentityStoreTests.package(pki: pki, client: "a", port: port, callsign: "PANE-1").write(to: package)
        defer { try? FileManager.default.removeItem(at: package) }

        let settings = MemorySettings()
        let connections = ServerConnections(settings: settings, identities: store)
        try connections.start()
        let added = try connections.importPackage(at: package)
        XCTAssertEqual(added.count, 1)
        let id = try XCTUnwrap(added.first?.id)
        try await waitFor("connected") { connections.status[id] == .connected }
        try await server.waitFor("tls client CN=a", within: 5)
        XCTAssertEqual(connections.callsign, "PANE-1")

        connections.setEnabled(id, false)
        XCTAssertEqual(connections.status[id], .off)
        try await server.waitFor("fake-cot: client disconnected", within: 10)
        await connections.stop()

        let reopened = ServerConnections(settings: settings, identities: store)
        XCTAssertEqual(reopened.uid, connections.uid)
        XCTAssertEqual(reopened.callsign, "PANE-1")
        XCTAssertEqual(reopened.servers.map(\.id), [id])
        XCTAssertEqual(reopened.servers.first?.enabled, false)
        reopened.remove(id)
        XCTAssertTrue(reopened.servers.isEmpty)
        XCTAssertTrue(ServerConnections(settings: settings, identities: store).servers.isEmpty)
    }

    func testARefusedConnectionShowsWhy() async throws {
        let store = try XCTUnwrap(keychain).store
        let port = try freePort()   // nothing listens
        let connections = ServerConnections(settings: MemorySettings(), identities: store)
        try connections.start()
        let server = ServerConfig(description: "nobody", address: ConnectString(host: "127.0.0.1", port: port, proto: .tcp))
        connections.add(server)
        try await waitFor("a failure") {
            if case .failed = connections.status[server.id] { true } else { false }
        }
        XCTAssertEqual(connections.status[server.id], .failed("connection refused"))
        await connections.stop()
    }

    /// An SSL server with no certificates says so instead of connecting.
    func testAServerWithoutCertificatesSaysSo() async throws {
        let store = try XCTUnwrap(keychain).store
        let connections = ServerConnections(settings: MemorySettings(), identities: store)
        try connections.start()
        let server = ServerConfig(description: "ops", address: ConnectString(host: "127.0.0.1", port: 8089, proto: .ssl))
        connections.add(server)
        try await waitFor("a failure") {
            if case .failed = connections.status[server.id] { true } else { false }
        }
        XCTAssertEqual(connections.status[server.id], .failed("ops: no truststore for 127.0.0.1:8089:ssl"))
        await connections.stop()
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else { throw CommoError(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// UserDefaults' part that ServerConnections uses, in memory.
final class MemorySettings: SettingsStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
