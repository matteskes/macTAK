// ExitRun.swift — one instance's part of the G3 exit run (dev/g3/NOTES.md
// §The G3 exit, PR b): an ExitScript carried out on a ServerConnections, as
// a user would do it by hand.
//
// 1. This instance's callsign and placed position, so its self-SA names it
//    and puts it somewhere, reported at ATAK's Constant rate (ExitScript's
//    reportEvery), set before it connects.
// 2. The server: any earlier exit server of the same name leaves the list;
//    the server's CA is imported as its truststore, and the server added
//    with enrollment, then enrolled as the script's user (G3.2c), which
//    connects it.
// 3. The peer: wait for it as a contact, by callsign.
// 4. A Spot Map point dropped with the Point Dropper and sent (5.5 sends a
//    dropped point only when asked); sent again every two seconds while the
//    run waits, as a first send just after a connection comes up can go
//    nowhere (CommoClient.sendableDelay) and a resent point replaces itself.
// 5. A chat to All Chat Rooms, once.
// 6. Wait for the peer's point, which it sends only once it has heard this
//    instance; then the one-to-one, once. Sent earlier, it could reach a peer
//    that doesn't know this instance yet, which sends no delivered receipt
//    (5.5's rule, ChatService.message).
// 7. Wait for both of the peer's chats; mark its one-to-one seen (the read
//    receipt goes back), and wait for the delivered and read receipts of
//    this instance's own one-to-one.
//
// Every step is timed into the report, and the report is written when the
// run ends, passed or not. A cleanup-only script removes the exit servers and
// their certificates instead (the exit run's tidy-up).

import Foundation
import MacTAKCot

@MainActor
public final class ExitRun {
    private let script: ExitScript
    private let connections: ServerConnections
    private let identities: IdentityStore
    private let environment: [String: String]
    private let started = Date()
    private var report = ExitReport()
    /// How often waits look again.
    private static let poll: Duration = .milliseconds(100)
    /// How often the dropped point is sent again while the run waits.
    private static let resendEvery: TimeInterval = 2

    public init(script: ExitScript, connections: ServerConnections, identities: IdentityStore,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.script = script
        self.connections = connections
        self.identities = identities
        self.environment = environment
    }

    /// Runs the script and writes its report; returns the report.
    @discardableResult
    public func run() async -> ExitReport {
        report.callsign = script.callsign
        report.uid = connections.uid
        do {
            if script.cleanupOnly {
                cleanup()
            } else {
                try await exercise()
            }
            report.passed = true
            step("passed")
        } catch {
            report.failure = "\(error)"
            step("failed")
        }
        do {
            try report.write(to: URL(fileURLWithPath: script.report))
        } catch {
            NSLog("macTAK: the exit report wasn't written: \(error)")
        }
        return report
    }

    // MARK: - the steps

    private func exercise() async throws {
        connections.me.details.callsign = script.callsign
        connections.me.details.reporting = .every(seconds: script.reportEvery)
        connections.me.place(script.place.point, address: nil)

        let server = try await enroll()
        step("enrolled")
        try await wait("connected to \(script.server.description)") { connections.status[server] == .connected }
        step("connected")

        let peer = try await waitForPeer(server: server)
        step("peer heard")
        try await Task.sleep(for: CommoClient.sendableDelay)

        let dropped = try drop()
        try connections.share(marker: dropped.uid)
        report.dropped = Self.marker(dropped)
        step("point dropped and sent")

        let chat = try service()
        try chat.send(script.allChatRooms, to: ChatRoom.allChatRooms)
        step("All Chat Rooms sent")

        var lastSend = Date()
        let resend = { [connections] in
            if Date().timeIntervalSince(lastSend) >= Self.resendEvery {
                try? connections.share(marker: dropped.uid)
                lastSend = Date()
            }
        }
        // the peer sends its point once it has heard this instance, and a
        // one-to-one gets its delivered receipt only from a peer that knows
        // the sender as a contact (ChatService.message, as 5.5)
        try await wait("\(script.peer)'s point") {
            resend()
            return peerMarker(peer) != nil
        }
        step("peer's point arrived")
        let direct = try chat.send(script.direct, to: peer.uid)
        step("one-to-one sent")

        try await wait("everything from \(script.peer)") {
            resend()
            return heardFromPeer(peer, chat: chat) && receiptsArrived(direct.messageId, chat: chat)
        }
        step("peer's chats and receipts arrived")
    }

    /// Steps 1: the truststore, the server, the enrollment.
    private func enroll() async throws -> UUID {
        let s = script.server
        for old in connections.servers where old.description == s.description { connections.remove(old.id) }
        guard let password = environment[s.passwordVariable], !password.isEmpty else {
            throw ExitError("\(s.passwordVariable) holds no password")
        }
        let ca = try Data(contentsOf: URL(fileURLWithPath: s.truststore))
        let truststore = try identities.importTruststore(pkcs12: ca, password: s.truststorePassword)
        report.truststore = truststore.hex
        let config = ServerConfig(description: s.description,
                                  address: ConnectString(host: s.host, port: s.port, proto: .ssl),
                                  enabled: false, enrollForCertificate: true, enrollUseTrust: true,
                                  truststore: truststore)
        connections.add(config)
        step("server added")
        try await connections.enroll(config.id, user: s.user, password: password, enrollmentPort: s.enrollmentPort)
        report.identity = connections.servers.first { $0.id == config.id }?.identity?.hex
        return config.id
    }

    private func waitForPeer(server: UUID) async throws -> Contact {
        var found: Contact?
        try await wait("\(script.peer) as a contact") {
            found = connections.contacts.contacts.first { $0.callsign == script.peer }
            return found != nil
        }
        let peer = try unwrap(found, "the peer")
        report.peer = ExitReport.Peer(uid: peer.uid, callsign: peer.callsign,
                                      viaServer: peer.paths.contains(.server(server)),
                                      viaMesh: peer.paths.contains(.mesh))
        return peer
    }

    private func drop() throws -> CotMarker {
        guard let color = PointKind.SpotMapColor(rawValue: script.pointColor) else {
            throw ExitError("no Spot Map colour \(script.pointColor)")
        }
        let dropper = connections.pointDropper
        dropper.begin(.spotMap(color))
        defer { dropper.end() }
        return try unwrap(dropper.click(.ground(script.point.point)), "the dropped point")
    }

    private func service() throws -> ChatService {
        try unwrap(connections.chat, "chat (no ChatStore)")
    }

    /// The peer's point and both of its chats, heard in this run; then its
    /// one-to-one is marked seen, which sends the read receipt.
    private func heardFromPeer(_ peer: Contact, chat: ChatService) -> Bool {
        let marker = peerMarker(peer)
        report.peerMarker = marker.map(Self.marker)
        let lines = (chat.history(ChatRoom.allChatRooms).filter { $0.senderUid == peer.uid }
            + chat.history(peer.uid).filter { !$0.outgoing })
            .filter { ($0.receiveTime ?? .distantPast) >= started }
        report.chats = lines.map { ExitReport.Chat(room: $0.conversationId, sender: $0.senderCallsign, text: $0.text) }
        let direct = lines.contains { $0.conversationId == peer.uid }
        if direct { chat.markSeen(peer.uid) }
        return marker != nil && direct && lines.contains { $0.conversationId == ChatRoom.allChatRooms }
    }

    /// The peer's Spot Map point, by its author, heard in this run: an
    /// instance keeps its map items and chats across launches.
    private func peerMarker(_ peer: Contact) -> CotMarker? {
        connections.markers.markers.first {
            $0.type == PointKind.spotMapType && Self.author(of: $0) == peer.uid && $0.lastHeard >= started
        }
    }

    private func receiptsArrived(_ messageId: String, chat: ChatService) -> Bool {
        let line = chat.history(report.peer?.uid ?? "").first { $0.messageId == messageId }
        let receipts = ExitReport.Receipts(delivered: line?.receiveTime != nil, read: line?.readTime != nil)
        report.receipts = receipts
        return receipts.delivered && receipts.read
    }

    /// Removes every server of the script's name, with its certificates.
    private func cleanup() {
        for server in connections.servers where server.description == script.server.description {
            report.removed += connections.removeWithCertificates(server.id).map(\.hex)
        }
        step("cleaned up")
    }

    // MARK: -

    private func step(_ name: String) {
        report.steps.append(ExitReport.Step(name: name, at: Date().timeIntervalSince(started)))
    }

    /// Waits until `done` holds, looking every 0.1 s; throws after the
    /// script's timeout.
    private func wait(_ what: String, _ done: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(script.timeout)
        while try !done() {
            guard Date() < deadline else {
                throw ExitError("timed out after \(Int(script.timeout)) s waiting for \(what)")
            }
            try await Task.sleep(for: Self.poll)
        }
    }

    private func unwrap<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw ExitError("no \(what)") }
        return value
    }

    private static func author(of marker: CotMarker) -> String? {
        Author(creator: marker.event.detail("creator"), orTime: .distantPast)?.uid
            ?? marker.event.detail("link")?["uid"]
    }

    private static func marker(_ m: CotMarker) -> ExitReport.Marker {
        ExitReport.Marker(uid: m.uid, label: m.label ?? "", type: m.type, lat: m.point.lat, lon: m.point.lon,
                          author: author(of: m))
    }
}

public struct ExitError: Error, CustomStringConvertible, Equatable {
    public let description: String
    init(_ description: String) { self.description = description }
}
