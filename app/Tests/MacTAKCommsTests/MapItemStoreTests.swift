// MapItemStoreTests.swift — G3.9a: the kept map items on disk, as 5.5's
// StateSaver table holds them: one row per uid, kept across reopening,
// loaded by query order and then as first saved.

import Foundation
import XCTest
@testable import MacTAKComms

final class MapItemStoreTests: XCTestCase {
    private var url: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("statesaver-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    private func item(_ uid: String, type: String = "a-h-G", event: String = "<event/>") -> StoredMapItem {
        StoredMapItem(uid: uid, type: type, event: event, lastUpdateTime: t0)
    }

    func testItemsSurviveReopening() throws {
        do {
            let store = try MapItemStore(url: url)
            try store.save(item("m1", event: "<event uid='m1'/>"))
            try store.save(StoredMapItem(uid: "m2", type: "u-rb-a", event: "<event uid='m2'/>", visible: false,
                                         lastUpdateTime: t0.addingTimeInterval(1.5)))
        }
        let items = try MapItemStore(url: url).items()
        XCTAssertEqual(items, [item("m1", event: "<event uid='m1'/>"),
                               StoredMapItem(uid: "m2", type: "u-rb-a", event: "<event uid='m2'/>", visible: false,
                                             lastUpdateTime: t0.addingTimeInterval(1.5))])
    }

    func testSavingAUIDAgainReplacesItsRowInPlace() throws {
        let store = try MapItemStore(url: url)
        try store.save(item("a", event: "old"))
        try store.save(item("b"))
        try store.save(item("a", event: "new"))
        XCTAssertEqual(try store.items().map(\.uid), ["a", "b"], "one row per uid, still loaded first")
        XCTAssertEqual(try store.items().first?.event, "new")
    }

    func testRemove() throws {
        let store = try MapItemStore(url: url)
        try store.save(item("a"))
        try store.save(item("b"))
        try store.remove(uid: "a")
        try store.remove(uid: "not-there")
        XCTAssertEqual(try store.items().map(\.uid), ["b"])
    }

    func testRoutesAndJumpPointsLoadAfterTheRest() throws {
        let store = try MapItemStore(url: url)
        try store.save(item("route", type: "b-m-r"))
        try store.save(item("dip", type: "b-m-p-j-dip"))
        try store.save(item("marker", type: "a-f-G"))
        try store.save(item("line", type: "u-rb-a"))
        XCTAssertEqual(try store.items().map(\.uid), ["marker", "line", "dip", "route"])
    }

    func testQueryOrderIsStateSaversByPrefix() {
        XCTAssertEqual(MapItemStore.queryOrder("b-m-r"), 2)
        XCTAssertEqual(MapItemStore.queryOrder("b-m-p-j-alt"), 1)
        XCTAssertEqual(MapItemStore.queryOrder("b-m-p-j"), 1)
        XCTAssertEqual(MapItemStore.queryOrder("b-m-p-w"), 0, "a waypoint isn't a route")
        XCTAssertEqual(MapItemStore.queryOrder("u-rb-a"), 0)
    }
}
