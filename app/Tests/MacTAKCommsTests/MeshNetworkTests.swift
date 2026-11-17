// G3.3b: the model under the app's Mesh section. The mesh is on unless
// turned off, and its settings persist; with commo started it runs on the
// interfaces it is given, shows each one up, and follows them as they come
// and go; turning it off closes them.
//
// The interfaces are injected (lo0, which the app itself never picks), and
// the ports are MeshTests'.

import Foundation
import XCTest
@testable import MacTAKComms

@MainActor
final class MeshNetworkTests: XCTestCase {
    private var keychain: TemporaryKeychain?
    private var connections: ServerConnections?

    override func setUp() async throws {
        keychain = try TemporaryKeychain()
    }

    override func tearDown() async throws {
        await connections?.stop()
        keychain?.delete()
    }

    func testOnByDefaultAndTheSettingsPersist() {
        let settings = MemorySettings()
        let mesh = MeshNetwork(settings: settings, available: { [] })
        XCTAssertTrue(mesh.enabled, "on by default, as ATAK has it")
        XCTAssertEqual(mesh.config, .atak)

        mesh.setEnabled(false)
        var changed = MeshConfig.atak
        changed.ttl = 8
        mesh.setConfig(changed)

        let reopened = MeshNetwork(settings: settings, available: { [] })
        XCTAssertFalse(reopened.enabled)
        XCTAssertEqual(reopened.config.ttl, 8)
    }

    func testRunsOnItsInterfacesAndFollowsThem() async throws {
        var available = ["lo0"]
        let mesh = try start(available: { available })
        try await waitFor("lo0 up") { mesh.interfaces["lo0"] == .up }
        try await waitFor("direct TCP up") { mesh.directTCP == .up }
        XCTAssertNil(mesh.problem)

        available = []
        mesh.refresh()
        await mesh.settle()
        XCTAssertEqual(mesh.interfaces, [:], "lo0 went away")

        available = ["lo0"]
        mesh.refresh()
        try await waitFor("lo0 back up") { mesh.interfaces["lo0"] == .up }
    }

    func testTurningItOffClosesEverything() async throws {
        let mesh = try start(available: { ["lo0"] })
        try await waitFor("lo0 up") { mesh.interfaces["lo0"] == .up }

        mesh.setEnabled(false)
        await mesh.settle()
        XCTAssertEqual(mesh.interfaces, [:])

        mesh.refresh()   // off: an interface change opens nothing
        await mesh.settle()
        XCTAssertEqual(mesh.interfaces, [:])

        mesh.setEnabled(true)
        try await waitFor("lo0 up again") { mesh.interfaces["lo0"] == .up }
    }

    func testAnInterfaceThatCannotOpenSaysWhy() async throws {
        let mesh = try start(available: { ["lo0", ""] })
        try await waitFor("lo0 up") { mesh.interfaces["lo0"] == .up }
        guard case .failed = mesh.interfaces[""] else {
            return XCTFail("an unnamed interface should fail, not \(String(describing: mesh.interfaces[""]))")
        }
    }

    /// A MeshNetwork on MeshTests' ports, with loopback on, run by a started
    /// ServerConnections.
    private func start(available: @escaping () -> [String]) throws -> MeshNetwork {
        let mesh = MeshNetwork(settings: MemorySettings(), available: available)
        mesh.setConfig(MeshTests.config(slot: 4))
        let store = try XCTUnwrap(keychain).store
        let connections = ServerConnections(settings: MemorySettings(), identities: store, mesh: mesh)
        self.connections = connections
        try connections.start()
        return mesh
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 15, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else { throw CommoError(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
