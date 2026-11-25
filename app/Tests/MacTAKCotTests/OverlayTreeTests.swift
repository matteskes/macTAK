// G3.11a: the Overlay Manager's tree as 5.5 builds it — overlays_hier.xml's
// overlays and how an item is placed (first match, exclusive, litmus, user
// icons), the top level, counts, empty lists hidden, the sorts, the field-
// of-view and Self-Authored filters, and search.

@testable import MacTAKCot
import XCTest

final class OverlayTreeTests: XCTestCase {
    private func item(_ uid: String, _ type: String, title: String? = nil, at p: CotPoint? = nil,
                      team: String? = nil, role: String? = nil, author: String? = nil,
                      iconset: String? = nil) -> OverlayItem {
        OverlayItem(id: uid, title: title ?? uid, type: type, location: p.map { .point($0) }, team: team,
                    role: role, author: author, iconsetPath: iconset)
    }

    private func place(_ type: String, team: String? = nil, role: String? = nil, iconset: String? = nil) -> [String] {
        OverlayConfig.place(item("u", type, team: team, role: role, iconset: iconset))
    }

    private func node(_ path: [String], in top: [OverlayTree.Node]) -> OverlayTree.Node? {
        var rows = top, found: OverlayTree.Node?
        for title in path {
            found = rows.first { $0.title == title }
            rows = found?.children ?? []
        }
        return found
    }

    private func p(_ lat: Double, _ lon: Double) -> CotPoint { CotPoint(lat: lat, lon: lon) }

    // MARK: - overlays_hier.xml

    func testEachMarkerOverlayTakesItsTypes() {
        let cases: [(String, String)] = [
            ("a-h-G", "hostile"), ("a-j-G", "hostile"), ("a-k-G", "hostile"),
            ("a-f-G-U-C-I", "friendlytroops"), ("a-f-G-E-V-C", "friendlygroundvehicles"),
            ("a-f-A-M-F", "friendlyairplatforms"), ("a-f-S-X", "friendlyships"), ("a-f-U-S", "friendlyships"),
            ("a-f-G-I-R", "friendlystructures"), ("a-f-G", "friendlyother"), ("a-f-G-U-H", "friendlyother"),
            ("a-n-G", "neutral"), ("a-u-G", "unknown"),
            ("b-m-p-s-m", "spotmap"), ("u-d-v", "vehicles"), ("b-m-r", "routes"),
            ("b-m-p-w-GOTO", "waypoints"), ("b-m-p-i", "waypoints"), ("b-m-t-h", "trackhistory"),
        ]
        for (type, overlay) in cases { XCTAssertEqual(place(type), [overlay], type) }
    }

    func testTypesNoOverlayNames() {
        XCTAssertEqual(place("a-p-G"), [], "pending: under the a- litmus, but no filter")
        XCTAssertEqual(place(RangeBearingEvent.type), [], "an R&B line is only in its group")
        XCTAssertEqual(place("b-m-p-w"), [], "a plain waypoint isn't a GOTO")
    }

    func testATeamMemberIsUnderItsTeamNotItsType() {
        XCTAssertEqual(place("a-f-G-U-C", team: "Cyan", role: "Team Member"), ["friendlyteamCyan"])
        XCTAssertEqual(place("a-f-G-U-C", team: "Dark Blue"), ["friendlyteamDarkBlue"])
        XCTAssertEqual(place("a-f-G-U-C", team: "Pink"), ["friendlyteamUnknown"], "an unknown team reads as Pink")
    }

    func testARoleIsNotExclusive() {
        XCTAssertEqual(place("a-f-G-U-C", team: "Cyan", role: "Team Lead"), ["friendlyteamleads", "friendlyteamCyan"])
        XCTAssertEqual(place("a-f-G-U-C", role: "Medic"), ["friendlyteammedic", "friendlytroops"],
                       "no team: nothing claims it, so the markers take it too")
    }

    func testTheLitmusRulesOutAFamily() {
        XCTAssertEqual(place("a-h-G", team: "Cyan", role: "Team Lead"), ["hostile"], "the team overlay is a-f only")
    }

    func testAUserIconIsLeftToTheIconsOverlay() {
        XCTAssertEqual(place("a-f-G", iconset: "6d781afb-89a6-4c07-b2b9-a89748b6a38f/Google/hiker.png"), [])
        XCTAssertEqual(place("a-f-G", iconset: "COT_MAPPING_2525C/a-f/a-f-G"), ["friendlyother"])
        XCTAssertEqual(place("b-m-p-s-m", iconset: "COT_MAPPING_SPOTMAP/b-m-p-s-m/-65536"), ["spotmap"])
        XCTAssertEqual(place("a-f-G", iconset: "hiker.png"), ["friendlyother"], "one part isn't a path")
        XCTAssertEqual(place("a-f-G", iconset: "set/group/"), [], "split drops the empty end")
    }

    // MARK: - the tree

    func testTheTopLevelByOrderEmptyListsHiddenButMarkers() {
        XCTAssertEqual(OverlayTree.build([]).map(\.title), ["Markers"])
        let items = [item("r", Route.type), item("t", "a-f-G", team: "Red"), item("h", "a-h-G"),
                     OverlayItem(id: "rb", title: "R&B 1", type: RangeBearingEvent.type, group: .rangeAndBearing)]
        let top = OverlayTree.build(items)
        XCTAssertEqual(top.map(\.title), ["Team", "Markers", "Navigation", "Shapes"])
        XCTAssertEqual(node(["Team"], in: top)?.children?.map(\.title), ["Red Team"])
        XCTAssertEqual(node(["Markers", "Markers"], in: top)?.children?.map(\.title), ["Red Markers"])
        XCTAssertEqual(node(["Navigation", "Routes"], in: top)?.children?.map(\.uid), ["r"])
        XCTAssertEqual(node(["Shapes", "Range & Bearing"], in: top)?.children?.map(\.title), ["R&B 1"])
    }

    func testCountsIncludeSubListsAsRows() throws {
        let top = OverlayTree.build([item("h1", "a-h-G"), item("h2", "a-h-G"), item("f", "a-f-G-U-C")])
        let markers = try XCTUnwrap(node(["Markers"], in: top))
        let affiliations = try XCTUnwrap(node(["Markers", "Markers"], in: top))
        let hostile = try XCTUnwrap(node(["Markers", "Markers", "Red Markers"], in: top))
        XCTAssertEqual(affiliations.children?.map(\.title), ["Red Markers", "Friendly Markers"])
        XCTAssertEqual(hostile.countText, "2 Items")
        XCTAssertEqual(affiliations.countText, "2 Items (6 including sub-items)")
        XCTAssertEqual(markers.countText, "1 Item (7 including sub-items)")
        XCTAssertNil(hostile.children?.first?.countText, "an item has no count")
    }

    func testATeamLeadIsInBothListsWithUniqueIds() throws {
        let top = OverlayTree.build([item("tl", "a-f-G", team: "Cyan", role: "Team Lead")])
        let team = try XCTUnwrap(node(["Team"], in: top))
        XCTAssertEqual(team.children?.map(\.title), ["Team Lead", "Cyan Team"])
        let rows = team.children!.flatMap { $0.children! }
        XCTAssertEqual(rows.map(\.uid), ["tl", "tl"])
        XCTAssertNotEqual(rows[0].id, rows[1].id)
    }

    // MARK: - sorting

    func testAlphabeticalIgnoresCaseThenUID() {
        let top = OverlayTree.build([item("3", "a-h-G", title: "bravo"), item("2", "a-h-G", title: "Alpha"),
                                     item("1", "a-h-G", title: "bravo"), item("4", "a-h-G", title: "charlie")])
        XCTAssertEqual(node(["Markers", "Markers", "Red Markers"], in: top)?.children?.map(\.uid), ["2", "1", "3", "4"])
    }

    func testByDistanceNearestFirstUnplacedLastListsFirst() {
        let here = p(37.79, -122.44)
        let items = [item("far", "a-f-G", title: "A", at: p(37.9, -122.44)),
                     item("near", "a-f-G", title: "Z", at: p(37.791, -122.44)),
                     item("none", "a-f-G", title: "B"),
                     item("troop", "a-f-G-U-C", at: p(37.79, -122.44))]
        let top = OverlayTree.build(items, sort: .distance(from: here))
        let friendly = node(["Markers", "Markers", "Friendly Markers"], in: top)
        XCTAssertEqual(friendly?.children?.map(\.title), ["Troops", "Other"], "lists stay first, by order")
        XCTAssertEqual(node(["Other"], in: friendly?.children ?? [])?.children?.map(\.uid), ["near", "far", "none"])
        let alpha = OverlayTree.build(items)
        XCTAssertEqual(node(["Markers", "Markers", "Friendly Markers", "Other"], in: alpha)?.children?.map(\.uid),
                       ["far", "none", "near"])
    }

    func testALineIsMeasuredFromItsCentre() {
        let here = p(0, 0)
        let route = OverlayItem(id: "r", title: "A", type: Route.type, location: .line([p(0, 1), p(0, 3)]))
        let close = OverlayItem(id: "c", title: "B", type: Route.type, location: .line([p(0, -1.5), p(0, 1.5)]))
        let top = OverlayTree.build([route, close], sort: .distance(from: here))
        XCTAssertEqual(node(["Navigation", "Routes"], in: top)?.children?.map(\.uid), ["c", "r"])
    }

    func testJavaCompareToIgnoreCase() {
        XCTAssertLessThan(JavaString.compareIgnoringCase("alpha", "Bravo"), 0)
        XCTAssertEqual(JavaString.compareIgnoringCase("ALPHA", "alpha"), 0)
        XCTAssertLessThan(JavaString.compareIgnoringCase("R&B 1", "R&B 10"), 0, "shorter first")
        XCTAssertGreaterThan(JavaString.compareIgnoringCase("R&B 2", "R&B 10"), 0, "not numeric")
        XCTAssertGreaterThan(JavaString.compareIgnoringCase("Z", "_"), 0, "letters compare folded to lower case")
    }

    // MARK: - filters

    private let view = FieldOfView(upperLeft: CotPoint(lat: 1, lon: -1), upperRight: CotPoint(lat: 1, lon: 1),
                                   lowerRight: CotPoint(lat: -1, lon: 1), lowerLeft: CotPoint(lat: -1, lon: -1))

    func testShowAllOffKeepsWhatIsInView() {
        let items = [item("in", "a-h-G", at: p(0.5, 0.5)), item("out", "a-h-G", at: p(5, 5)), item("nowhere", "a-h-G")]
        let top = OverlayTree.build(items, filters: .init(fieldOfView: view))
        XCTAssertEqual(node(["Markers", "Markers", "Red Markers"], in: top)?.children?.map(\.uid), ["in"])
        let gone = OverlayTree.build([items[1]], filters: .init(fieldOfView: view))
        XCTAssertNil(node(["Markers", "Markers"], in: gone), "a list left empty is hidden")
    }

    func testALineCrossingTheViewIsInIt() {
        XCTAssertTrue(view.contains(.line([p(0, -5), p(0, 5)])), "no point in view, but it crosses")
        XCTAssertFalse(view.contains(.line([p(5, -5), p(5, 5)])))
        XCTAssertTrue(view.contains(.line([p(0.5, 0.5), p(9, 9)])))
        XCTAssertFalse(view.contains(.line([p(0.5, 0.5)])), "a line needs two points")
    }

    func testATurnedViewIsAQuadrilateral() {
        let diamond = FieldOfView(upperLeft: p(0, -1), upperRight: p(1, 0), lowerRight: p(0, 1), lowerLeft: p(-1, 0))
        XCTAssertTrue(diamond.contains(p(0, 0)))
        XCTAssertFalse(diamond.contains(p(0.9, 0.9)), "inside the bounds, outside the diamond")
        XCTAssertTrue(diamond.contains(.line([p(0.9, 0.9), p(0.95, 0.95)])),
                      "a line's point only has to be inside the bounds")
        XCTAssertTrue(diamond.contains(.line([p(-2, 0), p(2, 0)])), "it crosses the diamond")
    }

    func testSelfAuthoredKeepsWhatThisDeviceMade() {
        let items = [item("mine", "a-h-G", author: "me"), item("theirs", "a-h-G", author: "them"),
                     item("nobody", "a-h-G")]
        let top = OverlayTree.build(items, filters: .init(author: "me"))
        XCTAssertEqual(node(["Markers", "Markers", "Red Markers"], in: top)?.children?.map(\.uid), ["mine"])
    }

    func testTheAuthorIsTheLastLinkOrCreator() {
        func author(_ xml: String) -> String? {
            OverlayItem.markerAuthor(of: try! CotEvent.parse(
                "<event version='2.0' uid='x' type='a-h-G' time='2026-01-01T00:00:00Z' start='2026-01-01T00:00:00Z'"
                    + " stale='2026-01-01T00:01:00Z' how='h-e'><point lat='0' lon='0' hae='0' ce='0' le='0'/>"
                    + "<detail>\(xml)</detail></event>").detail)
        }
        XCTAssertEqual(author("<link uid='A' relation='p-p' type='a-f-G'/>"), "A")
        XCTAssertEqual(author("<link uid='A' relation='p-p'/><creator uid='B'/>"), "B")
        XCTAssertEqual(author("<link uid='A' relation='p-p'/><link uid='U' relation='r-u' url='x'/>"), "A",
                       "a url link isn't a parent")
        XCTAssertNil(author("<link uid='A' relation='p-p'/><creator uid=''/>"), "an empty creator removes it")
        XCTAssertNil(author(""))
    }

    // MARK: - search

    func testSearchFindsRowsNotTheListsHoldingThem() {
        let top = OverlayTree.build([item("h", "a-h-G", title: "Bridge"), item("f", "a-f-G", title: "Ridge camp")])
        XCTAssertEqual(OverlayTree.search("RIDGE", in: top).map(\.uid), ["h", "f"])
        XCTAssertEqual(OverlayTree.search("  ", in: top), [])
    }

    func testAMatchingListIsFoundItself() {
        let top = OverlayTree.build([item("h", "a-h-G", title: "Alpha")])
        XCTAssertEqual(OverlayTree.search("red", in: top).map(\.uid), ["hostile"])
        XCTAssertEqual(OverlayTree.search("markers", in: top).map(\.uid), ["affiliations", "markerroot"],
                       "the top list and the list under it, by order; not searched into")
    }

    func testARouteIsFoundByItsWaypoints() {
        var route = OverlayItem(id: "r", title: "Patrol", type: Route.type)
        route.searchNames = ["Patrol SP", "Bridge", "VDO"]
        let top = OverlayTree.build([route, item("h", "a-h-G", title: "Alpha")])
        XCTAssertEqual(OverlayTree.search("bridge", in: top).map(\.uid), ["r"])
    }

    func testOneResultPerUID() {
        let top = OverlayTree.build([item("tl", "a-f-G", title: "Lead", team: "Cyan", role: "Team Lead")])
        XCTAssertEqual(OverlayTree.search("lead", in: top).map(\.uid), ["friendlyteamleads", "tl"],
                       "the Team Lead list matches; the Cyan Team's row is found once")
    }
}
