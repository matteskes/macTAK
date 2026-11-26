// OverlayTree.swift — the Overlay Manager's tree (G3.11a), as ATAK 5.5's
// HierarchyListAdapter shows MapOverlayManager's overlays:
//
// - the top level, by order (MENU_ITEM_COMP): Team (the XML's friendlyteam,
//   0), Markers (the "markerroot" parent, 2), Navigation (5) and Shapes
//   (the "shapesoverlays" parent, 7). The XML's overlays with parent
//   "markerroot" sit under Markers; the Range & Bearing map group sits
//   under Shapes (RangeAndBearingMapComponent); the Route Manager's list
//   is Navigation › Routes (RouteListModel).
// - a filter overlay's list (FilterMapOverlay.ListModelImpl) shows its
//   child overlays first, by order, then its own items, sorted. An item is
//   listed when every filter on passes: the field of view (Show All off)
//   and Self-Authored (the item's author is this device). A filter never
//   drops a list.
// - an empty list is hidden (EmptyListFilter; hideIfEmpty), all but
//   Markers, whose parent is made always visible (UserMapComponent).
// - a list's counts: its rows ("N Items") and, when more, its rows and
//   all its lists' rows below ("(M including sub-items)";
//   getDescendantCount counts a list as a row of its parent too).
// - the sorts the lists offer (getDefaultSortModes): alphabetical, and by
//   distance when a row has a place. Alphabetical is MENU_ITEM_COMP: lists
//   by order, then titles ignoring case, then uids. By distance, from the
//   self marker (else the map's centre): rows with a place first, nearest
//   first, then the rest alphabetically. A filter overlay keeps its child
//   lists first either way. (5.5's Z–A sort, SortAlphabetDesc, is offered
//   only by the TAK server channel lists; these lists fall back to
//   alphabetical.)
// - a search (searchImpl) asks each top-level list's Search.find, and
//   finds the list itself when its lowered title holds the term as typed
//   (rootSearchEngine). Each list's find lowers the term and:
//   - a filter overlay (ListModelImpl): a row whose title holds it, else
//     a child overlay's find; a list that matches isn't searched into;
//   - Routes (RouteListModel): a route by its title or a waypoint's
//     callsign;
//   - a parent (MapOverlayParent, Markers and Shapes): its lists' finds,
//     not their titles;
//   - the Range & Bearing group (MapGroupHierarchyListItem): an item
//     whose lowered title matches "*term*" ('*' in the term a wildcard).
//   One row per uid, sorted as the lists are.

import Foundation

public enum OverlayTree {
    /// MapOverlayParent ids and the Range & Bearing group's name.
    public static let markersID = "markerroot", shapesID = "shapesoverlays", rangeAndBearingID = "Range & Bearing"
    /// The Route Manager's overlay.
    public static let routesID = "routes"

    public enum Sort: Sendable, Equatable {
        case alphabetical
        /// SortDistanceFrom: from this point (the self marker's, else the
        /// map's centre).
        case distance(from: CotPoint)
    }

    /// The filters on; nil is off.
    public struct Filters: Sendable, Equatable {
        /// FOVFilter: Show All off.
        public var fieldOfView: FieldOfView?
        /// AuthorFilter: Self-Authored on, with this device's uid.
        public var author: String?

        public init(fieldOfView: FieldOfView? = nil, author: String? = nil) {
            self.fieldOfView = fieldOfView; self.author = author
        }

        func accept(_ item: OverlayItem) -> Bool {
            if let fieldOfView, !fieldOfView.contains(item.location) { return false }
            if let author, item.author != author { return false }
            return true
        }
    }

    public struct Node: Sendable, Equatable, Identifiable {
        /// Its path from the top, unique in the tree (an item can be in two
        /// lists, and the XML repeats an id).
        public var id: String
        /// The overlay's id, or the item's uid.
        public var uid: String
        public var title: String
        /// The list's icon and colour (the XML's); nil for an item.
        public var icon: String?
        public var iconColor: String?
        /// The item; nil for a list.
        public var item: OverlayItem?
        /// A list's rows; nil for an item.
        public var children: [Node]?
        /// getPreferredListIndex: a list's order; -1 for an item.
        public var order: Int
        /// Which of 5.5's list classes it is, for search.
        var kind: Kind = .item

        enum Kind: Sendable, Equatable {
            case item
            /// FilterMapOverlay.ListModelImpl (RouteListModel for Routes).
            case overlay
            /// MapOverlayParent.
            case parent
            /// MapGroupHierarchyListItem.
            case group
        }

        public var isList: Bool { children != nil }

        /// getChildCount.
        public var childCount: Int { children?.count ?? 0 }

        /// getDescendantCount: its rows, and its lists' descendants.
        public var descendantCount: Int {
            guard let children else { return 0 }
            return children.count + children.reduce(0) { $0 + $1.descendantCount }
        }

        /// The row's count, as HierarchyListAdapter writes it; nil for an
        /// item.
        public var countText: String? {
            guard isList else { return nil }
            var text = childCount == 1 ? "1 Item" : "\(childCount) Items"
            if childCount > 0, descendantCount > childCount { text += " (\(descendantCount) including sub-items)" }
            return text
        }

        /// The point the distance sort measures from.
        var center: CotPoint? { item?.center }

        /// EmptyListFilter: an empty list that hides when empty.
        var isHiddenEmpty: Bool { isList && childCount == 0 && uid != OverlayTree.markersID }
    }

    // MARK: - building

    /// The top-level lists over `items`, empty ones hidden.
    public static func build(_ items: [OverlayItem], filters: Filters = Filters(), sort: Sort = .alphabetical,
                             overlays: [OverlayConfig] = OverlayConfig.atak) -> [Node] {
        var placed: [String: [OverlayItem]] = [:]
        for item in items where filters.accept(item) {
            for id in OverlayConfig.place(item, in: overlays) { placed[id, default: []].append(item) }
        }
        let builder = Builder(placed: placed, sort: sort)

        var top = overlays.filter { $0.parent == nil }.map { builder.list($0, path: "") }
        let markers = overlays.filter { $0.parent == markersID }
        top.append(builder.parent(id: markersID, title: "Markers", icon: "asset://icons/affiliations.png", order: 2,
                                  children: markers.map { builder.list($0, path: "/" + markersID) }))
        let rangeAndBearing = items.filter { $0.group == .rangeAndBearing && filters.accept($0) }
        top.append(builder.parent(id: shapesID, title: "Shapes", icon: "asset://icons/shape.png", order: 7, children: [
            builder.group(id: rangeAndBearingID, title: "Range & Bearing", icon: "asset://icons/rangebearing.png",
                          items: rangeAndBearing, path: "/" + shapesID),
        ]))
        return top.filter { !$0.isHiddenEmpty }.sorted(by: alphabetical)
    }

    private struct Builder {
        let placed: [String: [OverlayItem]]
        let sort: Sort

        /// A filter overlay's list: its child lists by order, then its items.
        func list(_ config: OverlayConfig, path: String) -> Node {
            let here = path + "/" + config.id + "#\(config.order)"
            let lists = config.children.map { list($0, path: here) }.sorted(by: alphabetical)
            let rows = rows(placed[config.id] ?? [], path: here)
            return Node(id: here, uid: config.id, title: config.title, icon: config.icon, iconColor: config.iconColor,
                        children: (lists + rows).filter { !$0.isHiddenEmpty }, order: config.order, kind: .overlay)
        }

        /// A MapOverlayParent's list.
        func parent(id: String, title: String, icon: String, order: Int, children: [Node]) -> Node {
            Node(id: "/" + id, uid: id, title: title, icon: icon,
                 children: children.filter { !$0.isHiddenEmpty }.sorted(by: alphabetical), order: order, kind: .parent)
        }

        /// A map group's list (MapGroupHierarchyListItem), no order of its own.
        func group(id: String, title: String, icon: String, items: [OverlayItem], path: String) -> Node {
            let here = path + "/" + id
            return Node(id: here, uid: id, title: title, icon: icon, children: rows(items, path: here), order: -1,
                        kind: .group)
        }

        func rows(_ items: [OverlayItem], path: String) -> [Node] {
            items.map { Node(id: path + "/" + $0.id, uid: $0.id, title: $0.title, item: $0, order: -1) }
                .sorted(by: OverlayTree.order(sort))
        }
    }

    // MARK: - searching

    /// The rows under `top` (the top-level lists) a search for `term`
    /// finds; none for an empty term (searchListAndFilterResults).
    public static func search(_ term: String, in top: [Node], sort: Sort = .alphabetical) -> [Node] {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var found: [Node] = []
        for list in top {
            found += find(term, in: list)
            // The root search (rootSearchEngine) lowers the title, not the term.
            if list.title.lowercased().contains(term) { found.append(list) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.uid).inserted }.sorted(by: order(sort))
    }

    /// A list's Search.find, by its class; each lowers the term first.
    private static func find(_ term: String, in list: Node) -> [Node] {
        let term = term.lowercased()
        let rows = list.children ?? []
        switch list.kind {
        case .item:
            return []
        case .parent:
            // MapOverlayParent: its lists' finds, not their titles.
            return rows.flatMap { find(term, in: $0) }
        case .group:
            // MapGroupHierarchyListItem: deepFindItems(field, "*term*").
            // String.matches: the whole value.
            let pattern = "^(?:" + wildcardRegex("*" + term + "*") + ")$"
            return rows.filter { $0.title.lowercased().range(of: pattern, options: .regularExpression) != nil }
        case .overlay where list.uid == routesID:
            // RouteListModel: a route's title, or a waypoint's callsign.
            return rows.filter { row in
                ([row.title] + (row.item?.searchNames ?? [])).contains { !$0.isEmpty && $0.lowercased().contains(term) }
            }
        case .overlay:
            // ListModelImpl: a row by its title, else into a list.
            return rows.flatMap { row -> [Node] in
                if !row.title.isEmpty, row.title.lowercased().contains(term) { return [row] }
                return row.kind == .overlay ? find(term, in: row) : []
            }
        }
    }

    /// WildCard.wildcardAsRegex(s, '*'): '*' is any run, "\\*" a literal
    /// '*', and the regex characters are escaped.
    static func wildcardRegex(_ s: String) -> String {
        var regex = "", previous: Character = " "
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            defer { previous = c; i += 1 }
            if previous == "*" && c == "*" { continue }
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "*" {
                regex += "\\*"
                i += 1
                continue
            }
            if c == "*" { regex += ".*"; continue }
            if "*\\[]^$?.{}+|()-:!&".contains(c) { regex += "\\" }
            regex.append(c)
        }
        return regex
    }

    // MARK: - sorting

    static func order(_ sort: Sort) -> (Node, Node) -> Bool {
        switch sort {
        case .alphabetical: alphabetical
        case .distance(let from): { nearer($0, $1, from: from) }
        }
    }

    /// MENU_ITEM_COMP.
    static func alphabetical(_ a: Node, _ b: Node) -> Bool { compare(a, b) < 0 }

    private static func compare(_ a: Node, _ b: Node) -> Int {
        switch (a.order >= 0, b.order >= 0) {
        case (true, true) where a.order != b.order: return a.order - b.order
        case (true, false): return -1
        case (false, true): return 1
        default: break
        }
        let titles = JavaString.compareIgnoringCase(a.title, b.title)
        return titles != 0 ? titles : JavaString.compareIgnoringCase(a.uid, b.uid)
    }

    /// ItemDistanceComparator.
    private static func nearer(_ a: Node, _ b: Node, from: CotPoint) -> Bool {
        switch (a.center, b.center) {
        case let (pa?, pb?):
            let da = Geodesy.distance(lat1: pa.lat, lon1: pa.lon, lat2: from.lat, lon2: from.lon)
            let db = Geodesy.distance(lat1: pb.lat, lon1: pb.lon, lat2: from.lat, lon2: from.lon)
            if da != db { return da < db }
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): break
        }
        return alphabetical(a, b)
    }
}

/// Java's String.compareToIgnoreCase: UTF-16 unit by unit, each folded to
/// upper then lower case.
extension JavaString {
    static func compareIgnoringCase(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf16), y = Array(b.utf16)
        for (c1, c2) in zip(x, y) where c1 != c2 {
            let u1 = fold(c1, upper: true), u2 = fold(c2, upper: true)
            guard u1 != u2 else { continue }
            let l1 = fold(u1, upper: false), l2 = fold(u2, upper: false)
            if l1 != l2 { return Int(l1) - Int(l2) }
        }
        return x.count - y.count
    }

    /// Character.toUpperCase / toLowerCase on one UTF-16 unit: a unit
    /// whose mapping isn't one unit stays as it is.
    private static func fold(_ unit: UInt16, upper: Bool) -> UInt16 {
        guard let scalar = Unicode.Scalar(unit) else { return unit }
        let mapped = upper ? scalar.properties.uppercaseMapping : scalar.properties.lowercaseMapping
        let units = Array(mapped.utf16)
        return units.count == 1 ? units[0] : unit
    }
}
