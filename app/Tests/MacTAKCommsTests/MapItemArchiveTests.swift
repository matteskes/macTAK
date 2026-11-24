// MapItemArchiveTests.swift — G3.9a's gate: the archived map items survive
// a relaunch, each launch a ServerConnections as the app makes it, on the
// same store file. An R&B line tied to a kept marker comes back tied to it
// (the line loads after the marker, or is deferred until it is in); what
// isn't archived isn't kept; a deleted item is gone from the store; quitting
// (stop) clears the markers without unkeeping them.

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class MapItemArchiveTests: XCTestCase {
    private var keychain: TemporaryKeychain?
    private var url: URL!
    private let here = CotPoint(lat: 37.795, lon: -122.445)
    private let there = CotPoint(lat: 37.8044, lon: -122.4194)

    override func setUp() async throws {
        keychain = try TemporaryKeychain()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("statesaver-\(UUID().uuidString).sqlite")
    }

    override func tearDown() async throws {
        keychain?.delete()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    /// One launch of the app's connections on the store file.
    private func launch() throws -> ServerConnections {
        let settings = MemorySettings()
        return ServerConnections(settings: settings, identities: try XCTUnwrap(keychain).store,
                                 me: .testing(settings), mapItemStore: try MapItemStore(url: url))
    }

    private func marker(_ uid: String, archive: Bool) -> String {
        let now = Date()
        var detail = CotDetail("detail")
        if archive { detail.add(CotDetail("archive")) }
        return CotEvent(uid: uid, type: "a-h-G", time: now, stale: now.addingTimeInterval(60), how: "h-g-i-g-o",
                        point: there, detail: detail).xml()
    }

    private func receive(_ c: ServerConnections, _ xml: String) {
        c.handle(.cot(xml: xml, endpoint: "test"))
    }

    func testALineTiedToAKeptMarkerSurvivesARelaunch() throws {
        do {
            let c = try launch()
            receive(c, marker("hostile-1", archive: true))
            let line = c.rangeBearing.add(start: .point(here), end: .item("hostile-1"))
            XCTAssertEqual(line.title, "R&B 1")
            c.syncArchive()
        }
        let c = try launch()
        XCTAssertEqual(c.markers["hostile-1"]?.point, there, "the kept marker is back")
        let line = try XCTUnwrap(c.rangeBearing.lines.first)
        XCTAssertEqual(line.title, "R&B 1")
        XCTAssertEqual(line.start, .point(here))
        XCTAssertEqual(line.end, .item("hostile-1"), "still tied to the marker")
        XCTAssertFalse(line.received, "made here")
        XCTAssertTrue(line.archived)
    }

    func testALineStoredBeforeItsMarkerIsDeferredUntilItIsIn() throws {
        let store = try MapItemStore(url: url)
        let line = RangeBearingEvent.make(uid: "line-1", title: "R&B 1", start: here, end: there, startUID: nil,
                                          endUID: "late-1", style: .atak, archive: true, creator: nil, now: Date())
        try store.save(StoredMapItem(uid: "line-1", type: "u-rb-a", event: line.xml(), lastUpdateTime: Date()))
        try store.save(StoredMapItem(uid: "late-1", type: "a-h-G", event: marker("late-1", archive: true),
                                     lastUpdateTime: Date()))
        XCTAssertEqual(try store.items().map(\.uid), ["line-1", "late-1"], "the line loads first")
        let c = try launch()
        XCTAssertEqual(c.rangeBearing["line-1"]?.end, .item("late-1"), "tied on the deferred try")
    }

    func testRestoreCountsOnlyWhatWasTaken() throws {
        let store = try MapItemStore(url: url)
        for uid in ["taken-1", "late-1", "never-1"] {
            try store.save(StoredMapItem(uid: uid, type: "a-h-G", event: uid, lastUpdateTime: Date()))
        }
        var tries: [String: Int] = [:]
        let taken = MapItemArchive(store: store, selfUID: "me").restore({ event in
            tries[event, default: 0] += 1
            switch event {
            case "taken-1": return .taken
            case "late-1": return tries[event] == 1 ? .deferred : .taken
            default: return .deferred
            }
        }, current: { [] })
        XCTAssertEqual(taken, 2, "one deferred twice isn't taken")
        XCTAssertEqual(tries, ["taken-1": 1, "late-1": 2, "never-1": 2])
    }

    func testWhatIsNotArchivedIsNotKept() throws {
        do {
            let c = try launch()
            receive(c, marker("passing-1", archive: false))
            let heard = RangeBearingEvent.make(uid: "heard-1", title: "R&B 9", start: here, end: there,
                                               startUID: nil, endUID: nil, style: .atak, creator: nil, now: Date())
            receive(c, heard.xml())
            c.rangeBearing.add(start: .point(here), end: .item("passing-1"))
            c.syncArchive()
        }
        let c = try launch()
        XCTAssertNil(c.markers["passing-1"])
        XCTAssertNil(c.rangeBearing["heard-1"], "a heard line without <archive/>")
        let line = try XCTUnwrap(c.rangeBearing.lines.first, "the line made here is kept")
        guard case .point(let end) = line.end else { return XCTFail("its marker wasn't kept: a fixed end") }
        XCTAssertEqual(end.lat, there.lat, accuracy: 1e-9, "where the marker was (range along bearing)")
        XCTAssertEqual(end.lon, there.lon, accuracy: 1e-9)
    }

    func testADeletedItemIsGoneFromTheStore() throws {
        do {
            let c = try launch()
            receive(c, marker("hostile-1", archive: true))
            let line = c.rangeBearing.add(start: .point(here), end: .point(there))
            c.syncArchive()
            XCTAssertEqual(try MapItemStore(url: url).items().count, 2)
            c.rangeBearing.remove(id: line.id)
            let now = Date()
            var detail = CotDetail("detail")
            var link = CotDetail("link")
            link["uid"] = "hostile-1"; link["relation"] = "none"; link["type"] = "none"
            detail.add(link)
            detail.add(CotDetail("__forcedelete"))
            receive(c, CotEvent(uid: "del", type: CotMarkerStore.deleteType, time: now, stale: now,
                                how: "h-g-i-g-o", point: here, detail: detail).xml())
            c.syncArchive()
        }
        XCTAssertTrue(try MapItemStore(url: url).items().isEmpty)
        let c = try launch()
        XCTAssertTrue(c.rangeBearing.lines.isEmpty)
        XCTAssertTrue(c.markers.markers.isEmpty)
    }

    func testStopClearsTheMarkersButKeepsThem() async throws {
        let c = try launch()
        receive(c, marker("hostile-1", archive: true))
        await c.stop()
        XCTAssertNil(c.markers["hostile-1"], "stop clears the map")
        XCTAssertEqual(try MapItemStore(url: url).items().map(\.uid), ["hostile-1"], "written before it cleared")
        let again = try launch()
        XCTAssertNotNil(again.markers["hostile-1"])
    }

    func testChangesAreWrittenWithoutBeingAsked() async throws {
        let c = try launch()
        c.rangeBearing.add(start: .point(here), end: .point(there))
        // the coalesced sync runs on the main queue's next turn
        try await waitFor("the line is written") { (try? MapItemStore(url: self.url).items().count) == 1 }
        XCTAssertNotNil(c)
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else { throw CommoError(description: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
