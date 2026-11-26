// G3.11b: what the Overlay Manager's rows do, as 5.5's hierarchy actions do
// it — a list's visibility from its rows (Visibility2), hiding a list hides
// its rows, a route takes its points with it when it changes
// (EditablePolyline.onVisibleChanged), Delete per kind (an R&B endpoint
// leaves the list, its line keeps the end), an item that leaves the map
// takes its visibility with it, GoTo's point (an Arrow's end, a route's
// centre) — and the gate's relaunch test: a hidden item stays hidden after
// a relaunch (StateSaverListener's `visible`, StateSaverPublisher's extra).

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class OverlayManagerTests: XCTestCase {
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

    private func marker(_ uid: String, at p: CotPoint? = nil, type: String = "a-h-G", archive: Bool = true) -> String {
        let now = Date()
        var detail = CotDetail("detail")
        if archive { detail.add(CotDetail("archive")) }
        return CotEvent(uid: uid, type: type, time: now, stale: now.addingTimeInterval(60), how: "h-g-i-g-o",
                        point: p ?? there, detail: detail).xml()
    }

    private func receive(_ c: ServerConnections, _ xml: String) {
        c.handle(.cot(xml: xml, endpoint: "test"))
    }

    /// The tree as the Overlay Manager builds it now; R&B lines where
    /// their ends are (as the map's tick places them).
    private func tree(_ c: ServerConnections) -> [OverlayTree.Node] {
        _ = c.rangeBearing.ends(markers: Dictionary(uniqueKeysWithValues: c.markers.markers.map { ($0.uid, $0.point) }))
        return OverlayTree.build(c.overlays.items())
    }

    private func node(_ uid: String, in nodes: [OverlayTree.Node]) -> OverlayTree.Node? {
        for n in nodes {
            if n.uid == uid { return n }
            if let found = node(uid, in: n.children ?? []) { return found }
        }
        return nil
    }

    // MARK: - visibility

    func testAListIsShownPartlyOrHiddenAsItsRowsAre() throws {
        let c = try launch()
        receive(c, marker("h1"))
        receive(c, marker("h2"))
        let hostile = try XCTUnwrap(node("hostile", in: tree(c)))
        XCTAssertEqual(c.overlays.visibility(of: hostile), .visible)
        c.overlays.setVisible(try XCTUnwrap(node("h1", in: [hostile])), false)
        XCTAssertEqual(c.overlays.visibility(of: hostile), .partial)
        XCTAssertFalse(c.visibility.isVisible("h1"))
        c.overlays.setVisible(try XCTUnwrap(node("h2", in: [hostile])), false)
        XCTAssertEqual(c.overlays.visibility(of: hostile), .hidden)
        var empty = hostile
        empty.children = []
        XCTAssertEqual(c.overlays.visibility(of: empty), .hidden, "no rows: getVisibility's INVISIBLE")
    }

    func testHidingAListHidesEachRowAndShowingShowsThem() throws {
        let c = try launch()
        receive(c, marker("h1"))
        receive(c, marker("h2"))
        let markers = try XCTUnwrap(node(OverlayTree.markersID, in: tree(c)))
        c.overlays.setVisible(markers, false)
        XCTAssertEqual(c.visibility.hidden, ["h1", "h2"])
        c.overlays.setVisible(markers, true)
        XCTAssertTrue(c.visibility.hidden.isEmpty)
    }

    func testARouteHidesAndShowsItsPointsWithItOnlyWhenItChanges() throws {
        let c = try launch()
        receive(c, marker("cp-1"))
        let route = c.routes.add(points: [RoutePoint.waypoint(here, uid: "wp-1", callsign: "SP"),
                                          RoutePoint.controlPoint(there, uid: "cp-1"),
                                          RoutePoint.waypoint(here, uid: "wp-2", callsign: "VDO")])
        let row = try XCTUnwrap(node(route.id, in: tree(c)))
        c.overlays.setVisible(row, false)
        XCTAssertEqual(c.visibility.hidden, [route.id, "wp-1", "cp-1", "wp-2"],
                       "its points, the marker it runs through with them")
        c.overlays.setVisible(try XCTUnwrap(node("cp-1", in: tree(c))), true)
        c.overlays.setVisible(row, false)
        XCTAssertTrue(c.visibility.isVisible("cp-1"), "the route was already hidden: nothing changed, nothing followed")
        c.overlays.setVisible(row, true)
        XCTAssertTrue(c.visibility.hidden.isEmpty)
    }

    func testAnItemThatLeavesTakesItsVisibilityWithIt() throws {
        let c = try launch()
        receive(c, marker("h1"))
        c.overlays.setVisible(try XCTUnwrap(node("h1", in: tree(c))), false)
        receive(c, marker("h1", at: here))
        c.overlays.prune()
        XCTAssertFalse(c.visibility.isVisible("h1"), "an update leaves it hidden")
        c.overlays.delete([try XCTUnwrap(node("h1", in: tree(c)))])
        c.overlays.prune()
        receive(c, marker("h1"))
        XCTAssertTrue(c.visibility.isVisible("h1"), "back after leaving: a new item, shown")
    }

    // MARK: - delete and go to

    func testDeleteTakesEachKindAndEveryRowOfAList() throws {
        let c = try launch()
        receive(c, marker("h1"))
        receive(c, marker("h2"))
        let line = c.rangeBearing.add(start: .point(here), end: .item("h1"))
        let route = c.routes.add(points: [RoutePoint.waypoint(here, uid: "wp-1", callsign: "SP"),
                                          RoutePoint.waypoint(there, uid: "wp-2", callsign: "VDO")])
        var nodes = tree(c)
        let endpoint = try XCTUnwrap(node(line.id + ".start", in: nodes))
        c.overlays.delete([endpoint])
        XCTAssertNil(node(line.id + ".start", in: tree(c)), "the endpoint leaves the list")
        XCTAssertNotNil(c.rangeBearing.lines.first, "its line keeps the end")
        nodes = tree(c)
        c.overlays.delete([try XCTUnwrap(node(line.id, in: nodes)), try XCTUnwrap(node(route.id, in: nodes)),
                           try XCTUnwrap(node("hostile", in: nodes))])
        XCTAssertTrue(c.rangeBearing.lines.isEmpty)
        XCTAssertNil(c.routes[route.id])
        XCTAssertTrue(c.markers.markers.isEmpty, "a list deletes every row")
    }

    func testGoToGoesToALinesEndARoutesCentreAndAPoint() throws {
        let c = try launch()
        receive(c, marker("h1"))
        c.rangeBearing.add(start: .point(here), end: .item("h1"))
        let route = c.routes.add(points: [RoutePoint.waypoint(here, uid: "wp-1", callsign: "SP"),
                                          RoutePoint.waypoint(there, uid: "wp-2", callsign: "VDO")])
        _ = tree(c)
        let items = Dictionary(uniqueKeysWithValues: c.overlays.items().map { ($0.id, $0) })
        let line = try XCTUnwrap(c.rangeBearing.lines.first)
        XCTAssertEqual(c.overlays.location(of: try XCTUnwrap(items[line.id])), there, "an Arrow's point 2")
        XCTAssertEqual(c.overlays.location(of: try XCTUnwrap(items[route.id])), route.center)
        XCTAssertEqual(c.overlays.location(of: try XCTUnwrap(items["h1"])), there)
    }

    // MARK: - the gate: kept across a relaunch

    func testAHiddenPointStaysHiddenAfterARelaunch() throws {
        do {
            let c = try launch()
            receive(c, marker("h1"))
            receive(c, marker("h2"))
            c.overlays.setVisible(try XCTUnwrap(node("h1", in: tree(c))), false)
            c.syncArchive()
            let rows = try MapItemStore(url: url).items()
            XCTAssertEqual(rows.first { $0.uid == "h1" }?.visible, false, "written hidden")
            XCTAssertEqual(rows.first { $0.uid == "h2" }?.visible, true)
        }
        let c = try launch()
        XCTAssertNotNil(c.markers["h1"])
        XCTAssertFalse(c.visibility.isVisible("h1"), "hidden after the relaunch")
        XCTAssertTrue(c.visibility.isVisible("h2"))
        c.overlays.setVisible(try XCTUnwrap(node("h1", in: tree(c))), true)
        c.syncArchive()
        XCTAssertEqual(try MapItemStore(url: url).items().first { $0.uid == "h1" }?.visible, true, "shown again is written")
    }

    func testAHiddenRouteAndLineStayHiddenAfterARelaunch() throws {
        let routeID: String, lineID: String
        do {
            let c = try launch()
            let route = c.routes.add(points: [RoutePoint.waypoint(here, uid: "wp-1", callsign: "SP"),
                                              RoutePoint.waypoint(there, uid: "wp-2", callsign: "VDO")])
            let line = c.rangeBearing.add(start: .point(here), end: .point(there))
            routeID = route.id
            lineID = line.id
            let nodes = tree(c)
            c.overlays.setVisible(try XCTUnwrap(node(route.id, in: nodes)), false)
            c.overlays.setVisible(try XCTUnwrap(node(line.id, in: nodes)), false)
            c.syncArchive()
        }
        let c = try launch()
        XCTAssertNotNil(c.routes[routeID])
        XCTAssertEqual(c.visibility.hidden, [routeID, "wp-1", "wp-2", lineID], "a route takes its points with it")
    }
}
