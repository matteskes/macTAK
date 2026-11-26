// ExitRunTests.swift — the G3 exit run's instance part (ExitRun, PR b of
// dev/g3/NOTES.md §The G3 exit), against the fake servers: enrollment
// (dev/g3/test/fake-enroll-server.py) and mutual-TLS CoT
// (dev/g1/headless/fake-cot-server.py --tls). Two ServerConnections play
// the two app instances, each with its own script, as `--exit-script` runs
// them; the real run against OpenTAKServer is PR c's.

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class ExitRunTests: XCTestCase {
    private var pki: TestPKI?
    private var keychain: TemporaryKeychain?
    private var servers: [FakeServer] = []
    private var clients: [ServerConnections] = []
    private var files: [URL] = []
    private static let password = "exit-pass"
    private static let passwordVariable = "MACTAK_EXIT_TEST_PASSWORD"

    override func setUp() async throws {
        pki = try TestPKI.make(clients: [])
        keychain = try TemporaryKeychain()
    }

    override func tearDown() async throws {
        for c in clients { await c.stop() }
        clients = []
        for s in servers { s.stop() }
        servers = []
        for f in files { try? FileManager.default.removeItem(at: f) }
        files = []
        keychain?.delete()
        pki?.remove()
    }

    private let placeA = ExitScript.Place(lat: 37.80, lon: -122.45)
    private let placeB = ExitScript.Place(lat: 37.81, lon: -122.44)
    private let pointA = ExitScript.Place(lat: 37.795, lon: -122.445)
    private let pointB = ExitScript.Place(lat: 37.805, lon: -122.435)

    // MARK: - the two instances

    func testTwoInstancesEnrollAndSeeEachOthersContactPointAndChats() async throws {
        let (enrollPort, cotPort) = try startServers()
        let a = try client("a"), b = try client("b")
        let scriptA = try script("A", peer: "B", user: "alice", place: placeA, point: pointA, color: "R",
                                 enrollPort: enrollPort, cotPort: cotPort)
        let scriptB = try script("B", peer: "A", user: "bob", place: placeB, point: pointB, color: "B",
                                 enrollPort: enrollPort, cotPort: cotPort)

        let (reportA, reportB) = try await runBoth(runner(scriptA, a), runner(scriptB, b))

        for (report, me, peer, peerPoint, peerColor) in [(reportA, a, b, pointB, "B"), (reportB, b, a, pointA, "R")] {
            XCTAssertTrue(report.passed, report.failure ?? "")
            XCTAssertEqual(report.uid, me.uid)
            XCTAssertNotNil(report.identity, "enrolled")
            XCTAssertNotNil(report.truststore)
            XCTAssertEqual(report.peer?.uid, peer.uid)
            XCTAssertEqual(report.peer?.viaServer, true, "heard through the server")
            XCTAssertEqual(report.peer?.viaMesh, false, "no mesh in a test client")
            let marker = try XCTUnwrap(report.peerMarker)
            XCTAssertEqual(marker.author, peer.uid)
            XCTAssertEqual(marker.type, PointKind.spotMapType)
            XCTAssertEqual(marker.label, "\(peerColor) 1")
            XCTAssertEqual(marker.lat, peerPoint.lat, accuracy: 1e-7)
            XCTAssertEqual(marker.lon, peerPoint.lon, accuracy: 1e-7)
            XCTAssertEqual(Set(report.chats.map(\.room)), [ChatRoom.allChatRooms, peer.uid])
            XCTAssertEqual(Set(report.chats.map(\.text)),
                           ["all from \(peer.callsign)", "direct from \(peer.callsign)"])
            XCTAssertEqual(report.receipts, ExitReport.Receipts(delivered: true, read: true))
            XCTAssertEqual(report.steps.map(\.name), ["server added", "enrolled", "connected", "peer heard",
                                                       "point dropped and sent", "All Chat Rooms sent",
                                                       "peer's point arrived", "one-to-one sent",
                                                       "peer's chats and receipts arrived", "passed"])
        }
        let written = try JSONDecoder().decode(ExitReport.self, from: Data(contentsOf: URL(fileURLWithPath: scriptA.report)))
        XCTAssertEqual(written, reportA, "the report is on disk")
        XCTAssertTrue(servers[0].log.contains("signed subject=CN=alice"), servers[0].log)
        XCTAssertTrue(servers[1].log.contains("tls client CN=alice"), servers[1].log)
        XCTAssertTrue(servers[1].log.contains("tls client CN=bob"), servers[1].log)
    }

    /// A starts well before B: A's first self-SA goes out before B is
    /// connected, so B hears A only from a later report (OpenTAKServer
    /// forwards only to the clients it has registered). At ATAK's Dynamic
    /// rate that is 180 s away; the script's Constant rate makes it seconds.
    func testAPeerThatStartsLaterStillHearsTheFirst() async throws {
        let (enrollPort, cotPort) = try startServers()
        let a = try client("a"), b = try client("b")
        let scriptA = try script("A", peer: "B", user: "alice", place: placeA, point: pointA, color: "R",
                                 enrollPort: enrollPort, cotPort: cotPort)
        let scriptB = try script("B", peer: "A", user: "bob", place: placeB, point: pointB, color: "B",
                                 enrollPort: enrollPort, cotPort: cotPort)
        let runA = try runner(scriptA, a), runB = try runner(scriptB, b)
        let first = Task { await runA.run() }
        try await waitFor("A connected", timeout: 15) { a.status.values.contains(.connected) }
        try await Task.sleep(for: .seconds(5))
        let second = Task { await runB.run() }
        let (reportA, reportB) = (await first.value, await second.value)
        XCTAssertTrue(reportA.passed, "\(reportA)")
        XCTAssertTrue(reportB.passed, "\(reportB)")
    }

    /// The instances keep their chats and map items across runs; a second
    /// run reports only what it heard itself.
    func testASecondRunCountsOnlyWhatItHeard() async throws {
        let (enrollPort, cotPort) = try startServers()
        let a = try client("a"), b = try client("b")
        let scriptA = try script("A", peer: "B", user: "alice", place: placeA, point: pointA, color: "R",
                                 enrollPort: enrollPort, cotPort: cotPort)
        let scriptB = try script("B", peer: "A", user: "bob", place: placeB, point: pointB, color: "B",
                                 enrollPort: enrollPort, cotPort: cotPort)
        let (firstA, _) = try await runBoth(runner(scriptA, a), runner(scriptB, b))
        let (secondA, secondB) = try await runBoth(runner(scriptA, a), runner(scriptB, b))
        XCTAssertTrue(secondA.passed, secondA.failure ?? "")
        XCTAssertTrue(secondB.passed, secondB.failure ?? "")
        XCTAssertEqual(secondA.chats.count, 2, "\(secondA.chats)")
        XCTAssertNotEqual(secondA.peerMarker?.uid, firstA.peerMarker?.uid, "the second run's point")
        XCTAssertEqual(secondA.peerMarker?.label, "B 2", "B still has its first point")
    }

    func testCleanupRemovesTheExitServerAndItsCertificates() async throws {
        let (enrollPort, cotPort) = try startServers()
        let a = try client("a"), b = try client("b")
        let scriptA = try script("A", peer: "B", user: "alice", place: placeA, point: pointA, color: "R",
                                 enrollPort: enrollPort, cotPort: cotPort)
        let scriptB = try script("B", peer: "A", user: "bob", place: placeB, point: pointB, color: "B",
                                 enrollPort: enrollPort, cotPort: cotPort)
        let (reportA, _) = try await runBoth(runner(scriptA, a), runner(scriptB, b))
        let store = try XCTUnwrap(keychain).store
        XCTAssertEqual(try store.identities().count, 2)

        var cleanup = scriptA
        cleanup.cleanupOnly = true
        let cleaned = try await runner(cleanup, a).run()
        XCTAssertTrue(cleaned.passed, cleaned.failure ?? "")
        XCTAssertEqual(Set(cleaned.removed), Set([reportA.identity, reportA.truststore].compactMap { $0 }))
        XCTAssertTrue(a.servers.isEmpty, "the exit server left A's list")
        XCTAssertEqual(try store.identities().count, 1, "only B's identity is left")
        XCTAssertEqual(cleaned.steps.map(\.name), ["cleaned up", "passed"])
    }

    // MARK: - refusals

    func testNoPasswordFailsAndStillReports() async throws {
        let a = try client("a")
        let scriptA = try script("A", peer: "B", user: "alice", place: placeA, point: pointA, color: "R",
                                 enrollPort: 1, cotPort: 1)
        let report = await ExitRun(script: scriptA, connections: a, identities: try XCTUnwrap(keychain).store,
                                   environment: [:]).run()
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.failure, "\(Self.passwordVariable) holds no password")
        XCTAssertEqual(report.steps.map(\.name), ["failed"])
        XCTAssertNotNil(try? Data(contentsOf: URL(fileURLWithPath: scriptA.report)), "a failed run reports too")
    }

    func testAPeerThatNeverComesTimesOut() async throws {
        let (enrollPort, cotPort) = try startServers()
        let a = try client("a")
        var scriptA = try script("A", peer: "NOBODY", user: "alice", place: placeA, point: pointA, color: "R",
                                 enrollPort: enrollPort, cotPort: cotPort)
        scriptA.timeout = 3
        let report = try await runner(scriptA, a).run()
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.failure, "timed out after 3 s waiting for NOBODY as a contact")
        XCTAssertEqual(report.steps.map(\.name), ["server added", "enrolled", "connected", "failed"])
    }

    func testTheScriptReadsFromJSON() throws {
        let json = """
        {"server": {"description": "exit", "host": "127.0.0.1", "port": 8089, "enrollmentPort": 8446,
                    "truststore": "/tmp/ca.p12", "truststorePassword": "atakatak", "user": "exit_a",
                    "passwordVariable": "MACTAK_EXIT_PASSWORD"},
         "callsign": "EXIT-A", "place": {"lat": 37.8, "lon": -122.45}, "reportEvery": 3, "peer": "EXIT-B",
         "point": {"lat": 37.795, "lon": -122.445}, "pointColor": "R",
         "allChatRooms": "hello all", "direct": "hello B", "timeout": 60, "report": "/tmp/a.json",
         "cleanupOnly": false}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exit-script-\(UUID()).json")
        files.append(url)
        try Data(json.utf8).write(to: url)
        let script = try ExitScript.load(url)
        XCTAssertEqual(script.server.user, "exit_a")
        XCTAssertEqual(script.server.enrollmentPort, 8446)
        XCTAssertEqual(script.peer, "EXIT-B")
        XCTAssertEqual(script.point.point, CotPoint(lat: 37.795, lon: -122.445))
        XCTAssertEqual(script.timeout, 60)
        XCTAssertEqual(script.reportEvery, 3)
    }

    // MARK: -

    /// The enrollment server, then the TLS CoT server, both on the test CA.
    private func startServers() throws -> (enroll: Int, cot: Int) {
        let pki = try XCTUnwrap(pki)
        let enrollPort = try freePort(), cotPort = try freePort()
        servers.append(try FakeServer.enroll(port: enrollPort, pki: pki, user: "alice,bob", password: Self.password))
        servers.append(try FakeServer.cot(port: cotPort, ["--tls", pki.serverCert, pki.serverKey,
                                                          "--client-ca", pki.caPEM]))
        return (enrollPort, cotPort)
    }

    /// One instance, as the app makes it, with chat and its own settings.
    private func client(_ name: String) throws -> ServerConnections {
        let settings = MemorySettings()
        let chatURL = FileManager.default.temporaryDirectory.appendingPathComponent("exit-chat-\(UUID()).sqlite")
        files.append(chatURL)
        let c = ServerConnections(settings: settings, identities: try XCTUnwrap(keychain).store,
                                  me: .testing(settings, uid: "g3-exit-\(name)-\(UUID().uuidString.prefix(8))"),
                                  chatStore: try ChatStore(url: chatURL))
        clients.append(c)
        try c.start()
        return c
    }

    private func script(_ callsign: String, peer: String, user: String, place: ExitScript.Place,
                        point: ExitScript.Place, color: String, enrollPort: Int, cotPort: Int) throws -> ExitScript {
        let truststore = FileManager.default.temporaryDirectory.appendingPathComponent("exit-ca-\(UUID()).p12")
        try XCTUnwrap(pki).truststore().pkcs12.write(to: truststore)
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("exit-report-\(UUID()).json")
        files += [truststore, report]
        return ExitScript(
            server: .init(description: "exit", host: "127.0.0.1", port: cotPort, enrollmentPort: enrollPort,
                          truststore: truststore.path, truststorePassword: TestPKI.password, user: user,
                          passwordVariable: Self.passwordVariable),
            callsign: callsign, place: place, peer: peer, point: point, pointColor: color,
            allChatRooms: "all from \(callsign)", direct: "direct from \(callsign)", timeout: 30,
            report: report.path)
    }

    /// Both instances at once, as the exit run launches them.
    private func runBoth(_ a: ExitRun, _ b: ExitRun) async -> (ExitReport, ExitReport) {
        let first = Task { await a.run() }, second = Task { await b.run() }
        return (await first.value, await second.value)
    }

    private func runner(_ script: ExitScript, _ connections: ServerConnections) throws -> ExitRun {
        ExitRun(script: script, connections: connections, identities: try XCTUnwrap(keychain).store,
                environment: [Self.passwordVariable: Self.password])
    }
}
