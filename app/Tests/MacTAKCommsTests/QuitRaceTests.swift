// #270, trap 23: a stream that comes up while commo shuts down. CommoImpl
// deletes its ContactManager before the streaming layer, whose connection
// thread runs until its own delete; without patch 0010 that thread told the
// freed ContactManager the stream was up, and the process died with
// SIGSEGV or SIGBUS. held-tls-server.py holds the handshake until the
// shutdown has begun, so the stream comes up inside that window.

import Foundation
import XCTest
@testable import MacTAKComms

final class QuitRaceTests: XCTestCase {
    /// Long enough for the shutdown to be under way, well short of its end
    /// (0.5 to 1.2 s on the dev Mac); 0 to 400 ms all crashed without 0010.
    private static let releaseAfterShutdownBegins: Duration = .milliseconds(20)

    func testShutdownSurvivesAStreamComingUp() async throws {
        let pki = try TestPKI.make(clients: ["a"])
        defer { pki.remove() }
        let port = try freePort()
        let release = pki.dir.appendingPathComponent("release").path
        let server = try FakeServer.heldTLS(port: port, pki: pki, releaseFile: release)
        defer { server.stop() }

        let client = try TwoClients.Client(uid: "g3-270-\(UUID().uuidString.prefix(8))")
        try await client.commo.connect(host: "127.0.0.1", port: port, transport: .ssl(try pki.credentials("a")))
        try await server.waitFor("held", within: 15)

        let closing = Task { await client.close() }
        try await Task.sleep(for: Self.releaseAfterShutdownBegins)
        FileManager.default.createFile(atPath: release, contents: nil)
        await closing.value

        XCTAssertTrue(server.log.contains("released"), server.log)
    }
}
