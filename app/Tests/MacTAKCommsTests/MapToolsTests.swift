// The map tools, one running at a time: starting one ends the one running
// (5.5's ToolManagerBroadcastReceiver), and a click on the map goes to the
// running tool, or back to the app when none runs.

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class MapToolsTests: XCTestCase {
    private let here = CotPoint(lat: 37.795, lon: -122.445)
    private let there = CotPoint(lat: 37.8044, lon: -122.4194)
    private let elsewhere = CotPoint(lat: 37.81, lon: -122.43)

    @MainActor
    private final class Fixture {
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        let routes: Routes
        let routeEditor: RouteEditor
        let dropper: PointDropper
        let rangeBearing = RangeBearingLines(newID: { "rb-1" })
        let editor: PointEditor
        let tools: MapTools

        init() {
            var n = 0
            let newID = { () -> String in n += 1; return "id-\(n)" }
            let locate = locating(markers)
            routes = Routes(newID: newID)
            routeEditor = RouteEditor(routes: routes, locate: locate, newID: newID)
            dropper = PointDropper(markers: markers, locate: locate, deviceCallsign: { "VIPER" }, newID: newID,
                                   timeZone: TimeZone(identifier: "UTC")!)
            editor = PointEditor(markers: markers, locate: locate)
            tools = MapTools(routeEditor: routeEditor, pointDropper: dropper, rangeBearing: rangeBearing,
                             pointEditor: editor)
        }

        /// A point the dropper placed at `p`, with the dropper ended.
        func placed(at p: CotPoint) throws -> String {
            dropper.begin(.affiliation(.hostile))
            let marker = try XCTUnwrap(dropper.click(.ground(p)))
            dropper.end()
            return marker.uid
        }

        func start(_ tool: MapTools.Tool, moving uid: String) {
            switch tool {
            case .route: routeEditor.begin()
            case .pointDropper: dropper.begin(.affiliation(.hostile))
            case .rangeBearing: rangeBearing.beginTool()
            case .pointMove: editor.beginMove(uid)
            }
        }
    }

    func testStartingAToolEndsTheRunningOne() throws {
        for first in MapTools.Tool.allCases {
            for second in MapTools.Tool.allCases where second != first {
                let f = Fixture()
                let uid = try f.placed(at: here)
                f.start(first, moving: uid)
                XCTAssertEqual(f.tools.active, first)
                f.start(second, moving: uid)
                XCTAssertEqual(f.tools.active, second, "\(second) after \(first)")
                XCTAssertEqual(f.routeEditor.editing != nil, second == .route, "\(first) → \(second)")
                XCTAssertEqual(f.dropper.selected != nil, second == .pointDropper, "\(first) → \(second)")
                XCTAssertEqual(f.rangeBearing.tool != .off, second == .rangeBearing, "\(first) → \(second)")
                XCTAssertEqual(f.editor.moving != nil, second == .pointMove, "\(first) → \(second)")
            }
        }
    }

    func testWithNoToolTheClickGoesBackToTheApp() throws {
        let f = Fixture()
        let uid = try f.placed(at: here)
        XCTAssertTrue(f.tools.isIdle)
        XCTAssertFalse(f.tools.click(.ground(there)))
        XCTAssertFalse(f.tools.click(.item(uid)))
        XCTAssertEqual(f.markers.markers.count, 1)
        XCTAssertNil(f.editor.inspected, "showing what was clicked is the app's")
    }

    func testAClickGoesToTheRunningTool() throws {
        let f = Fixture()
        let uid = try f.placed(at: here)

        f.dropper.begin(.affiliation(.hostile))
        XCTAssertTrue(f.tools.click(.ground(there)))
        XCTAssertEqual(f.markers.markers.count, 2, "the dropper placed a point")

        f.rangeBearing.beginTool()
        XCTAssertTrue(f.tools.click(.item(uid)))
        XCTAssertEqual(f.rangeBearing.tool, .pickingEnd(.item(uid)))

        f.routeEditor.begin()
        XCTAssertTrue(f.tools.click(.ground(there)))
        XCTAssertEqual(f.routes.routes.first?.points.count, 1, "the route tool added a waypoint")
        f.routeEditor.end()

        f.editor.beginMove(uid)
        XCTAssertTrue(f.tools.click(.ground(elsewhere)))
        XCTAssertEqual(f.markers[uid]?.point, elsewhere)
        XCTAssertTrue(f.tools.isIdle, "a move ends itself")
    }

    func testOtherToolsTakeARoutesPointAsTheGround() throws {
        let f = Fixture()
        f.routeEditor.begin()
        XCTAssertTrue(f.tools.click(.ground(here)))
        XCTAssertTrue(f.tools.click(.ground(there)))
        let routePoint = try XCTUnwrap(f.routes.routes.first?.points.first?.uid)
        f.routeEditor.end()

        f.dropper.begin(.affiliation(.hostile))
        XCTAssertTrue(f.tools.click(.item(routePoint)))
        let dropped = try XCTUnwrap(f.markers.markers.first)
        XCTAssertEqual(dropped.point.lat, here.lat, accuracy: 1e-9)
        XCTAssertEqual(dropped.point.lon, here.lon, accuracy: 1e-9)
    }

    func testTheDropperShowsAPointItPlacedInsteadOfDroppingOnIt() throws {
        let f = Fixture()
        f.dropper.begin(.affiliation(.hostile))
        let marker = try XCTUnwrap(f.dropper.click(.ground(here)))
        XCTAssertTrue(f.tools.click(.item(marker.uid)))
        XCTAssertEqual(f.editor.inspected, marker.uid)
        XCTAssertEqual(f.markers.markers.count, 1)
        XCTAssertEqual(f.tools.active, .pointDropper, "the dropper keeps running")
    }
}
