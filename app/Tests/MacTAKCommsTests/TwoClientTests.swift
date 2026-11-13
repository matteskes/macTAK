// Two CommoClients through dev/g1/headless/fake-cot-server.py: G1's
// round-trip contract (dev/g1/headless/run.sh) from Swift. Two clients
// because a TAK server does not echo a client's own events back to it.
//
// A connects and beacons; B connects, beacons and drops a marker. Passing
// means both interfaces came up, A sees B as a contact and gets B's marker,
// and B gets A's presence.

import Foundation
import XCTest
@testable import MacTAKComms

final class TwoClientTests: XCTestCase {
    private var server: Process?

    override func tearDown() {
        server?.terminate()
        server?.waitUntilExit()
        server = nil
    }

    func testTwoClientsSeeEachOther() async throws {
        let port = try startFakeServer()
        let tag = UUID().uuidString.prefix(8).lowercased()
        let uidA = "g3-comms-\(tag)-a", uidB = "g3-comms-\(tag)-b"

        let a = try CommoClient(uid: uidA, callsign: uidA.uppercased())
        let b = try CommoClient(uid: uidB, callsign: uidB.uppercased())
        let seenA = Recorder(), seenB = Recorder()
        let drainA = Task { for await e in a.events { await seenA.add(e) } }
        let drainB = Task { for await e in b.events { await seenB.add(e) } }

        await a.startBeacon(every: .seconds(1))
        try await a.connect(host: "127.0.0.1", port: port)
        try await seenA.wait("A's interface up", timeout: 15) { if case .interfaceUp = $0 { true } else { false } }

        await b.startBeacon(every: .seconds(1))
        try await b.connect(host: "127.0.0.1", port: port)
        try await seenB.wait("B's interface up", timeout: 15) { if case .interfaceUp = $0 { true } else { false } }
        try await Task.sleep(for: CommoClient.sendableDelay)
        let markerUid = "\(uidB)-m1"
        try await b.broadcast(Self.marker(uid: markerUid, lat: 37.7749, lon: -122.4194))

        try await seenA.wait("A sees B as a contact", timeout: 15) { $0 == .contactAdded(uid: uidB) }
        try await seenA.wait("A gets B's marker", timeout: 15) { Self.isCot($0, uid: markerUid) }
        try await seenB.wait("B gets A's presence", timeout: 15) { Self.isCot($0, uid: uidA) }

        await a.shutdown()
        await b.shutdown()
        _ = await (drainA.value, drainB.value)   // events end on shutdown
    }

    func testShutDownClientRefusesToSend() async throws {
        let client = try CommoClient(uid: "g3-comms-closed", callsign: "G3-COMMS-CLOSED")
        await client.shutdown()
        do {
            try await client.broadcast(Presence(uid: "x", callsign: "x").xml())
            XCTFail("a shut-down client sent")
        } catch let error as CommoError {
            XCTAssertEqual(error.description, "commo is shut down")
        }
    }

    func testPresenceEscapesItsText() {
        let xml = Presence(uid: "a'b", callsign: "O'BRIEN & <CO>\n").xml()
        XCTAssertTrue(xml.contains("uid='a&apos;b'"))
        XCTAssertTrue(xml.contains("callsign='O&apos;BRIEN &amp; &lt;CO&gt;&#10;'"))
        XCTAssertFalse(xml.contains("O'BRIEN"))
    }

    // MARK: - helpers

    private static func isCot(_ event: CommoEvent, uid: String) -> Bool {
        guard case let .cot(xml, _) = event else { return false }
        return xml.contains("uid='\(uid)'") || xml.contains("uid=\"\(uid)\"")
    }

    /// A dropped point, as G1's CotXml.marker builds it.
    private static func marker(uid: String, lat: Double, lon: Double) -> String {
        let t = Cot.time(Date()), stale = Cot.time(Date().addingTimeInterval(120))
        return "<event version='2.0' uid='\(uid)' type='a-f-G-U-C' access='Undefined'"
            + " time='\(t)' start='\(t)' stale='\(stale)' how='h-g-i-g-o'>"
            + "<point lat='\(lat)' lon='\(lon)' ce='10.0' le='10.0' hae='0.0'/>"
            + "<detail><contact callsign='\(uid.uppercased())'/></detail></event>"
    }

    /// fake-cot-server.py on a free loopback port; returns the port once it listens.
    private func startFakeServer() throws -> Int {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = repo.appendingPathComponent("dev/g1/headless/fake-cot-server.py")
        let port = try Self.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path, String(port)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        server = p
        // Wait for its "listening" line, bounded.
        let deadline = Date().addingTimeInterval(10)
        var text = ""
        while Date() < deadline, !text.contains("listening") {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        guard text.contains("listening") else {
            throw CommoError(description: "fake-cot-server.py did not start: \(text)")
        }
        // Keep draining its output so a full pipe never blocks it.
        out.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        return port
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CommoError(description: "socket failed") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { throw CommoError(description: "bind failed") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// Every event one client saw, and a bounded wait for one that matches.
private actor Recorder {
    private var events: [CommoEvent] = []

    func add(_ e: CommoEvent) { events.append(e) }

    func wait(_ what: String, timeout: TimeInterval,
              _ match: @Sendable (CommoEvent) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if events.contains(where: match) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let seen = events.map { "\($0)".prefix(160) }.joined(separator: "\n  ")
        throw CommoError(description: "timed out after \(Int(timeout)) s waiting for: \(what); saw:\n  \(seen)")
    }
}
