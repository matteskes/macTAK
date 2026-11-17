// G1's round-trip contract (dev/g1/headless/run.sh) between two
// CommoClients, over whichever transport a leg names. Two clients because a
// TAK server does not echo a client's own events back to it.
//
// A connects and beacons; B connects, beacons and drops a marker. Passing
// means both interfaces came up, A sees B as a contact and gets B's marker,
// and B gets A's presence.

import Foundation
@testable import MacTAKComms

enum TwoClients {
    /// Runs the round trip against a server on 127.0.0.1:`port`;
    /// `transport` gives each client ("a", "b") its transport.
    static func roundTrip(port: Int, transport: (String) throws -> CommoTransport) async throws {
        let tag = UUID().uuidString.prefix(8).lowercased()
        let uidA = "g3-comms-\(tag)-a", uidB = "g3-comms-\(tag)-b"

        let a = try Client(uid: uidA)
        let b = try Client(uid: uidB)

        await a.commo.startBeacon(every: .seconds(1))
        try await a.commo.connect(host: "127.0.0.1", port: port, transport: transport("a"))
        try await a.seen.wait("A's interface up", timeout: 15, isInterfaceUp)

        await b.commo.startBeacon(every: .seconds(1))
        try await b.commo.connect(host: "127.0.0.1", port: port, transport: transport("b"))
        try await b.seen.wait("B's interface up", timeout: 15, isInterfaceUp)
        try await Task.sleep(for: CommoClient.sendableDelay)
        let markerUid = "\(uidB)-m1"
        try await b.commo.broadcast(marker(uid: markerUid))

        try await a.seen.wait("A sees B as a contact", timeout: 15) { $0 == .contactAdded(uid: uidB) }
        try await a.seen.wait("A gets B's marker", timeout: 15) { isCot($0, uid: markerUid) }
        try await b.seen.wait("B gets A's presence", timeout: 15) { isCot($0, uid: uidA) }

        await a.close()
        await b.close()
    }

    /// One CommoClient with its events recorded.
    final class Client: Sendable {
        let commo: CommoClient
        let seen = Recorder()
        private let drain: Task<Void, Never>

        init(uid: String) throws {
            commo = try CommoClient(uid: uid, callsign: uid.uppercased())
            let (events, seen) = (commo.events, seen)
            drain = Task { for await e in events { await seen.add(e) } }
        }

        func close() async {
            await commo.shutdown()
            await drain.value   // events end on shutdown
        }
    }

    @Sendable static func isInterfaceUp(_ event: CommoEvent) -> Bool {
        if case .interfaceUp = event { true } else { false }
    }

    @Sendable static func isCot(_ event: CommoEvent, uid: String) -> Bool {
        guard case let .cot(xml, _) = event else { return false }
        return xml.contains("uid='\(uid)'") || xml.contains("uid=\"\(uid)\"")
    }

    /// A dropped point, as G1's CotXml.marker builds it.
    static func marker(uid: String, lat: Double = 37.7749, lon: Double = -122.4194) -> String {
        let t = Cot.time(Date()), stale = Cot.time(Date().addingTimeInterval(120))
        return "<event version='2.0' uid='\(uid)' type='a-f-G-U-C' access='Undefined'"
            + " time='\(t)' start='\(t)' stale='\(stale)' how='h-g-i-g-o'>"
            + "<point lat='\(lat)' lon='\(lon)' ce='10.0' le='10.0' hae='0.0'/>"
            + "<detail><contact callsign='\(uid.uppercased())'/></detail></event>"
    }
}

/// Every event one client saw, and bounded waits on them.
actor Recorder {
    private var events: [CommoEvent] = []

    func add(_ e: CommoEvent) { events.append(e) }

    func wait(_ what: String, timeout: TimeInterval,
              _ match: @Sendable (CommoEvent) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if events.contains(where: match) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CommoError(description: "timed out after \(Int(timeout)) s waiting for: \(what); saw:\n  \(summary)")
    }

    /// Fails if a matching event arrives within `period`.
    func never(_ what: String, within period: TimeInterval,
               _ match: @Sendable (CommoEvent) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(period)
        while Date() < deadline {
            if events.contains(where: match) {
                throw CommoError(description: "\(what) happened; saw:\n  \(summary)")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private var summary: String { events.map { "\($0)".prefix(160) }.joined(separator: "\n  ") }
}
