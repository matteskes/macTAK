// G3.10c: the route tool and the route details, each expectation read off
// 5.5 at the pin (RouteEditTool, the route menus' actions,
// RouteCreationDialog): what a click adds, what ending the tool does, undo,
// dragging, the menus' changes, a line's hit, the inspector.

import Foundation
import MacTAKCot
import XCTest
@testable import MacTAKComms

@MainActor
final class RouteEditorTests: XCTestCase {
    private func place(_ n: Int) -> CotPoint { CotPoint(lat: 37.79 + Double(n) * 0.001, lon: -122.44) }

    private func setUp(places: [String: CotPoint] = [:]) -> (Routes, RouteEditor) {
        var n = 0
        let newID = { () -> String in n += 1; return "id-\(n)" }
        let routes = Routes(newID: newID)
        let markers = CotMarkerStore(selfUID: "me") { _ in false }
        return (routes, RouteEditor(routes: routes, locate: locating(markers, places: places), newID: newID))
    }

    /// A route drawn with the tool through `n` ground clicks, still edited.
    private func drawn(_ n: Int, places: [String: CotPoint] = [:]) -> (Routes, RouteEditor, String) {
        let (routes, editor) = setUp(places: places)
        editor.begin()
        for i in 0..<n { editor.click(.ground(place(i))) }
        return (routes, editor, editor.editing!)
    }

    private func types(_ route: Route?) -> [String] {
        route?.points.map { $0.isWaypoint ? "w" : $0.isControlPoint ? "c" : "m" } ?? []
    }

    // MARK: - the tool

    func testANewRouteIsRouteNAndTheToolEditsIt() {
        let (routes, editor) = setUp()
        editor.begin()
        XCTAssertEqual(routes.routes.map(\.title), ["Route 1"])
        XCTAssertEqual(editor.editing, routes.routes.first?.id)
        XCTAssertTrue(editor.creating)
        XCTAssertNotNil(editor.prompt)
    }

    func testTheFirstClickIsAWaypointTheRestControlPoints() {
        let (routes, _, id) = drawn(3)
        XCTAssertEqual(types(routes[id]), ["w", "c", "c"])
        XCTAssertEqual(routes[id]?.points.map(\.point), [place(0), place(1), place(2)])
    }

    func testAnOptionClickIsAWaypoint() {
        let (routes, editor, id) = drawn(1)
        editor.click(.ground(place(1)), checkpoint: true)
        editor.click(.ground(place(2)))
        XCTAssertEqual(types(routes[id]), ["w", "w", "c"])
    }

    func testAClickOnAMarkerIsANewWaypointAtItsPoint() {
        let (routes, editor, id) = drawn(1, places: ["hostile-1": place(7)])
        XCTAssertTrue(editor.click(.item("hostile-1")))
        let last = routes[id]?.points.last
        XCTAssertEqual(last?.point, place(7))
        XCTAssertEqual(last?.isWaypoint, true)
        XCTAssertNotEqual(last?.uid, "hostile-1", "5.5 makes a new waypoint there; the marker stays apart")
    }

    func testAClickOnTheRoutesOwnPointAddsNothing() {
        let (routes, editor, id) = drawn(2)
        let first = routes[id]!.points[0].uid
        XCTAssertFalse(editor.click(.item(first)))
        XCTAssertEqual(routes[id]?.points.count, 2)
    }

    func testAClickOnAnotherRoutesPointIsAWaypointThere() {
        let (routes, editor, first) = drawn(2)
        editor.end()
        let other = routes[first]!.points[1]
        editor.begin()
        editor.click(.item(other.uid))
        XCTAssertEqual(routes[editor.editing!]?.points.map(\.point), [other.point])
    }

    func testEndingMakesTheEndsWaypointsAndNamesThem() {
        let (routes, editor, id) = drawn(3)
        editor.end()
        XCTAssertNil(editor.editing)
        XCTAssertEqual(types(routes[id]), ["w", "c", "w"])
        XCTAssertEqual(routes[id]?.points.map(\.callsign), ["Route 1 SP", nil, "VDO"])
    }

    func testEndingUnderTwoPointsRemovesTheRoute() {
        let (routes, editor, _) = drawn(1)
        editor.end()
        XCTAssertTrue(routes.routes.isEmpty)
        editor.begin()
        editor.end()
        XCTAssertTrue(routes.routes.isEmpty)
    }

    func testStartingTheToolAgainEndsTheRouteBefore() {
        let (routes, editor, first) = drawn(2)
        editor.begin()
        XCTAssertNotEqual(editor.editing, first)
        XCTAssertEqual(types(routes[first]), ["w", "w"], "the first route's tool ended")
        XCTAssertEqual(routes.routes.map(\.title), ["Route 1", "Route 2"])
    }

    func testEditingAnExistingRouteExtendsItWithControlPoints() {
        let (routes, editor, id) = drawn(2)
        editor.end()
        editor.edit(id)
        XCTAssertFalse(editor.creating)
        editor.click(.ground(place(5)))
        editor.end()
        XCTAssertEqual(types(routes[id]), ["w", "w", "w"], "the new end is made a waypoint")
        XCTAssertEqual(routes[id]?.points.map(\.callsign), ["Route 1 SP", "CP1", "VDO"])
    }

    // MARK: - undo

    func testUndoTakesBackTheLastChange() {
        let (routes, editor, id) = drawn(3)
        XCTAssertTrue(editor.canUndo)
        editor.undo()
        XCTAssertEqual(routes[id]?.points.map(\.point), [place(0), place(1)])
        editor.undo()
        editor.undo()
        XCTAssertEqual(routes[id]?.points.count, 0)
        XCTAssertFalse(editor.canUndo)
        editor.end()
        XCTAssertTrue(editor.history.isEmpty)
    }

    func testADragIsOneUndoStep() {
        let (routes, editor, id) = drawn(2)
        let uid = routes[id]!.points[1].uid
        editor.beginDrag(uid)
        editor.drag(uid, to: .ground(place(5)))
        editor.drag(uid, to: .ground(place(6)))
        XCTAssertEqual(routes[id]?.points[1].point, place(6))
        editor.undo()
        XCTAssertEqual(routes[id]?.points[1].point, place(1))
        editor.beginDrag(uid)
        editor.drag(uid, to: .ground(place(7)))
        editor.beginDrag(uid)
        editor.drag(uid, to: .ground(place(8)))
        editor.undo()
        XCTAssertEqual(routes[id]?.points[1].point, place(7), "two drags, two steps")
    }

    // MARK: - dragging

    func testOnlyTheEditedRoutesPointsDrag() {
        let (routes, editor, id) = drawn(2)
        let uid = routes[id]!.points[0].uid
        XCTAssertTrue(editor.canDrag(uid))
        XCTAssertFalse(editor.canDrag("hostile-1"))
        editor.end()
        XCTAssertFalse(editor.canDrag(uid), "a route drags only while edited")
        XCTAssertFalse(editor.drag(uid, to: .ground(place(9))))
    }

    // MARK: - the menus

    func testAWaypointBecomesAControlPointAndBack() {
        let (routes, editor, id) = drawn(3)
        editor.click(.ground(place(3)), checkpoint: true)
        editor.makeControlPoint(routes[id]!.points[3].uid)
        XCTAssertEqual(types(routes[id]), ["w", "c", "c", "c"])
        let control = routes[id]!.points[1].uid
        editor.makeWaypoint(control)
        XCTAssertEqual(types(routes[id]), ["w", "w", "c", "c"])
        XCTAssertNotEqual(routes[id]?.points[1].uid, control, "createWayPoint: a new uid")
        XCTAssertEqual(routes[id]?.points[1].point, place(1))
    }

    func testDeletePointTakesItOutOfTheLine() {
        let (routes, editor, id) = drawn(3)
        editor.deletePoint(routes[id]!.points[1].uid)
        XCTAssertEqual(routes[id]?.points.map(\.point), [place(0), place(2)])
    }

    func testInsertGoesAfterTheSegmentHit() {
        let (routes, editor, id) = drawn(3)
        let at = CotPoint(lat: 37.7905, lon: -122.44)
        editor.insert(RouteHit(route: id, segment: 0, point: at), waypoint: true)
        XCTAssertEqual(routes[id]?.points.map(\.point), [place(0), at, place(1), place(2)])
        XCTAssertEqual(routes[id]?.points[1].isWaypoint, true)
        editor.insert(RouteHit(route: id, segment: 2, point: at), waypoint: false)
        XCTAssertEqual(routes[id]?.points[3].isControlPoint, true)
    }

    func testThePointMenusChangeOnlyTheEditedRoute() {
        let (routes, editor, id) = drawn(3)
        editor.end()
        let before = routes[id]
        editor.deletePoint(before!.points[1].uid)
        editor.insert(RouteHit(route: id, segment: 0, point: place(9)), waypoint: true)
        XCTAssertEqual(routes[id], before)
    }

    // MARK: - the inspector

    func testTheInspectorShowsARouteThatExists() {
        let (routes, editor, id) = drawn(2)
        editor.inspect(id)
        XCTAssertEqual(editor.inspected, id)
        editor.inspect("nope")
        XCTAssertNil(editor.inspected)
        XCTAssertNotNil(routes[id])
    }

    func testAnInspectorChangeIsAnUndoStepOnlyWhileEdited() {
        let (routes, editor, id) = drawn(2)
        editor.update(id) { $0.color = -65536 }
        editor.undo()
        XCTAssertEqual(routes[id]?.color, Route.white)
        editor.end()
        editor.update(id) { $0.color = -65536 }
        XCTAssertEqual(routes[id]?.color, -65536)
        XCTAssertTrue(editor.history.isEmpty)
    }

    func testDeleteRemovesTheRouteAndLetsItGo() {
        let (routes, editor, id) = drawn(2)
        editor.inspect(id)
        editor.delete(id)
        XCTAssertNil(routes[id])
        XCTAssertNil(editor.editing)
        XCTAssertNil(editor.inspected)
    }

    func testLabelsToggle() {
        let (routes, editor, id) = drawn(2)
        editor.toggleLabels(id)
        XCTAssertEqual(routes[id]?.labelsOn, true)
        editor.toggleLabels(id)
        XCTAssertEqual(routes[id]?.labelsOn, false)
    }

    func testRouteWithPointFindsWaypointsAndControlPoints() {
        let (routes, editor, id) = drawn(2)
        XCTAssertEqual(editor.route(withPoint: routes[id]!.points[1].uid)?.id, id)
        XCTAssertNil(editor.route(withPoint: "hostile-1"))
        XCTAssertTrue(editor.isEditedPoint(routes[id]!.points[0].uid))
    }

    // MARK: - a line's hit

    func testTheNearestLineWithinTheRadiusAndItsSegment() {
        let a = [CotPoint(lat: 37.79, lon: -122.44), CotPoint(lat: 37.79, lon: -122.43), CotPoint(lat: 37.80, lon: -122.43)]
        let b = [CotPoint(lat: 37.7902, lon: -122.44), CotPoint(lat: 37.7902, lon: -122.43)]
        let nearA = CotPoint(lat: 37.79005, lon: -122.435)   // ~5.6 m from a, ~16.7 m from b
        XCTAssertEqual(RouteHit.nearest([("a", a), ("b", b)], to: nearA, within: 10),
                       RouteHit(route: "a", segment: 0, point: nearA))
        XCTAssertNil(RouteHit.nearest([("a", a)], to: CotPoint(lat: 37.7905, lon: -122.435), within: 10), "55 m off")
        let onSecond = CotPoint(lat: 37.795, lon: -122.43005)
        XCTAssertEqual(RouteHit.nearest([("a", a)], to: onSecond, within: 10)?.segment, 1)
        let nearB = CotPoint(lat: 37.79015, lon: -122.435)   // ~16.7 m from a, ~5.6 m from b
        XCTAssertEqual(RouteHit.nearest([("a", a), ("b", b)], to: nearB, within: 20)?.route, "b", "the nearer")
        XCTAssertNil(RouteHit.nearest([("a", [a[0]])], to: a[0], within: 10), "one point is no line")
    }
}
