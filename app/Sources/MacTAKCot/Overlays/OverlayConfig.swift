// OverlayConfig.swift — the Overlay Manager's filter overlays (G3.11a), as
// ATAK 5.5 builds them from filters/overlays_hier.xml (MapOverlayConfig,
// MapOverlayFilter, FilterMapOverlay):
//
// - an overlay holds the map items its filters match: a CoT type prefix
//   (TypeFilter: the item's type starts with it) or an item value equal to
//   a literal (MetaStringFilter: "team", "atakRoleType"); any filter will
//   do. An overlay with no filters holds no items, only its children.
// - a litmus filter (a type prefix) rules an item out of the overlay and
//   all its children before anything else is tried.
// - an item goes to the first overlay that takes it, in the XML's order: an
//   overlay that takes it stops its children trying, and an exclusive one
//   (the default) also claims it (filterOverlayId), so no other exclusive
//   overlay anywhere takes it. A non-exclusive overlay (the team roles)
//   takes it and lets the overlays after it try too, so a Team Lead on the
//   Cyan team is under both.
// - an item with a user icon set (an iconsetpath that isn't the 2525C or
//   Spot Map mapping) is left to the Icons overlay; no filter overlay
//   takes it (preAccept).
//
// The overlays here are the XML's, in its order, with its ids, orders and
// titles as 5.5 shows them in the civilian build (the filter_title_ and
// filter_absolute_ strings; "%s Team" for a team colour).

import Foundation

public struct OverlayConfig: Sendable, Equatable, Identifiable {
    public enum Filter: Sendable, Equatable {
        /// TypeFilter: the item's CoT type starts with this.
        case type(String)
        /// MetaStringFilter: the item's value of this name equals this.
        case item(name: String, value: String)
    }

    public var id: String
    /// The id of the overlay parent it sits under ("markerroot"); nil at
    /// the top of the tree. A nested overlay sits under the one it's in.
    public var parent: String?
    public var title: String
    /// The XML's icon ("asset://icons/target.png").
    public var icon: String
    /// The XML's iconColor ("cyan", "#FFFF7700"); nil for none.
    public var iconColor: String?
    /// Where it sorts among its siblings (MENU_ITEM_COMP).
    public var order: Int
    public var litmus: String?
    public var exclusive: Bool
    public var filters: [Filter]
    public var children: [OverlayConfig]

    public init(id: String, parent: String? = nil, title: String, icon: String, iconColor: String? = nil,
                order: Int, litmus: String? = nil, exclusive: Bool = true, filters: [Filter] = [],
                children: [OverlayConfig] = []) {
        self.id = id; self.parent = parent; self.title = title; self.icon = icon; self.iconColor = iconColor
        self.order = order; self.litmus = litmus; self.exclusive = exclusive
        self.filters = filters; self.children = children
    }
}

// MARK: - placing an item

extension OverlayConfig {
    /// The ids of the overlays among `overlays` (the top level, in order)
    /// that take `item`, as FilterMapOverlay.addItem places it.
    public static func place(_ item: OverlayItem, in overlays: [OverlayConfig] = atak) -> [String] {
        var placement = Placement(item: item)
        for overlay in overlays { _ = placement.add(to: overlay) }
        return placement.ids
    }

    private struct Placement {
        let item: OverlayItem
        var ids: [String] = []
        /// filterOverlayId: the exclusive overlay that took the item.
        var claimed = false

        /// addItem: whether `overlay` took the item exclusively.
        mutating func add(to overlay: OverlayConfig) -> Bool {
            guard preAccept(overlay) else { return false }
            if overlay.accepts(item) {
                ids.append(overlay.id)
                if overlay.exclusive { claimed = true }
                return overlay.exclusive
            }
            for child in overlay.children where add(to: child) { break }
            return false
        }

        func preAccept(_ overlay: OverlayConfig) -> Bool {
            if claimed && overlay.exclusive { return false }
            if item.hasUserIcon { return false }
            if let litmus = overlay.litmus, !item.type.hasPrefix(litmus) { return false }
            return true
        }
    }

    /// Whether one of its own filters matches `item`.
    func accepts(_ item: OverlayItem) -> Bool {
        filters.contains { filter in
            switch filter {
            case .type(let prefix): item.type.hasPrefix(prefix)
            case .item(let name, let value): item.value(named: name) == value
            }
        }
    }
}

// MARK: - overlays_hier.xml

extension OverlayConfig {
    /// overlays_hier.xml, as 5.5 ships it.
    public static let atak: [OverlayConfig] = [team, affiliations, spotMap, vehicles, navigation]

    private static let roleIcon = "asset://icons/roles/team.png"

    private static func role(_ id: String, _ title: String, icon: String, order: Int) -> OverlayConfig {
        OverlayConfig(id: id, title: title, icon: "asset://icons/roles/\(icon).png", order: order,
                      exclusive: false, filters: [.item(name: OverlayItem.roleKey, value: title)])
    }

    private static func teamColor(_ id: String, _ team: String, color: String, order: Int,
                                  title: String? = nil) -> OverlayConfig {
        OverlayConfig(id: id, title: title ?? "\(team) Team", icon: roleIcon, iconColor: color, order: order,
                      filters: [.item(name: OverlayItem.teamKey, value: team)])
    }

    static let team = OverlayConfig(
        id: "friendlyteam", title: "Team", icon: roleIcon, order: 0, litmus: "a-f",
        children: [
            role("friendlyteamleads", "Team Lead", icon: "teamlead", order: 0),
            role("friendlyteamhqelements", "HQ", icon: "hq", order: 1),
            role("friendlyteamsniper", "Sniper", icon: "sniper", order: 2),
            role("friendlyteammedic", "Medic", icon: "medic", order: 3),
            role("friendlyteamfo", "Forward Observer", icon: "forwardobserver", order: 4),
            role("friendlyteamrto", "RTO", icon: "rto", order: 5),
            role("friendlyteamk9", "K9", icon: "k9", order: 6),
            teamColor("friendlyteamCyan", "Cyan", color: "cyan", order: 7),
            teamColor("friendlyteamgWhite", "White", color: "white", order: 8),
            teamColor("friendlyteamYellow", "Yellow", color: "yellow", order: 9),
            teamColor("friendlyteamOrange", "Orange", color: "#FFFF7700", order: 10),
            teamColor("friendlyteamMagenta", "Magenta", color: "magenta", order: 11),
            teamColor("friendlyteamRed", "Red", color: "red", order: 12),
            teamColor("friendlyteamMaroon", "Maroon", color: "#FF7F0000", order: 13),
            teamColor("friendlyteamPurple", "Purple", color: "#FF7F007F", order: 14),
            teamColor("friendlyteamDarkBlue", "Dark Blue", color: "#FF00007F", order: 15),
            teamColor("friendlyteamBlue", "Blue", color: "blue", order: 16),
            teamColor("friendlyteamTeal", "Teal", color: "#FF007F7F", order: 17),
            teamColor("friendlyteamGreen", "Green", color: "green", order: 18),
            teamColor("friendlyteamDarkGreen", "Dark Green", color: "#FF007F00", order: 19),
            // Both ids are the XML's: Brown's is "friendlyteamUnknown" too.
            teamColor("friendlyteamUnknown", "Brown", color: "#FF964B00", order: 20),
            teamColor("friendlyteamUnknown", "Pink", color: "#FFFF1493", order: 21, title: "Unknown Team"),
        ])

    static let affiliations = OverlayConfig(
        id: "affiliations", parent: OverlayTree.markersID, title: "Markers", icon: "asset://icons/affiliations.png",
        order: 1, litmus: "a-",
        children: [
            OverlayConfig(id: "hostile", title: "Red Markers", icon: "asset://icons/target.png", order: 0,
                          filters: [.type("a-h"), .type("a-j"), .type("a-k")]),
            OverlayConfig(id: "friendly", title: "Friendly Markers", icon: "asset://icons/friendly.png", order: 1,
                          children: [
                OverlayConfig(id: "friendlytroops", title: "Troops",
                              icon: "asset://mil-std-2525c/sfgpuc---------.png", order: 2,
                              filters: [.type("a-f-G-U-C")]),
                OverlayConfig(id: "friendlygroundvehicles", title: "Ground Vehicles",
                              icon: "asset://mil-std-2525c/sfgpev---------.png", order: 3,
                              filters: [.type("a-f-G-E-V")]),
                OverlayConfig(id: "friendlyairplatforms", title: "Air Platforms",
                              icon: "asset://mil-std-2525c/sfapmf---------.png", order: 4,
                              filters: [.type("a-f-A")]),
                OverlayConfig(id: "friendlyships", title: "Ships",
                              icon: "asset://mil-std-2525c/sfspcl---------.png", order: 5,
                              filters: [.type("a-f-S"), .type("a-f-U")]),
                OverlayConfig(id: "friendlystructures", title: "Structures",
                              icon: "asset://mil-std-2525c/sfgpime---h----.png", order: 6,
                              filters: [.type("a-f-G-I")]),
                OverlayConfig(id: "friendlyother", title: "Other", icon: "asset://icons/friendly.png", order: 7,
                              filters: [.type("a-f")]),
            ]),
            OverlayConfig(id: "neutral", title: "Neutral Markers", icon: "asset://icons/neutral.png", order: 2,
                          filters: [.type("a-n")]),
            OverlayConfig(id: "unknown", title: "Unknown Markers", icon: "asset://icons/unknown.png", order: 3,
                          filters: [.type("a-u")]),
        ])

    static let spotMap = OverlayConfig(
        id: "spotmap", parent: OverlayTree.markersID, title: "Spot Map", icon: "asset://icons/reference_point.png",
        order: 4, litmus: "b-m-p-s-m", filters: [.type("b-m-p-s-m")])

    static let vehicles = OverlayConfig(
        id: "vehicles", parent: OverlayTree.markersID, title: "Vehicles", icon: "asset://icons/aircraft.png",
        order: 5, litmus: "u-d-v", filters: [.type("u-d-v"), .type("u-d-v-m")])

    static let navigation = OverlayConfig(
        id: "nav", title: "Navigation", icon: "asset://icons/green_flag.png", order: 5, litmus: "b-m-",
        children: [
            OverlayConfig(id: OverlayTree.routesID, title: "Routes", icon: "asset://icons/routes.png", order: 0,
                          filters: [.type("b-m-r")]),
            OverlayConfig(id: "waypoints", title: "Waypoints", icon: "asset://icons/green_flag.png", order: 1,
                          filters: [.type("b-m-p-w-GOTO"), .type("b-m-p-i")]),
            OverlayConfig(id: "trackhistory", title: "Track History", icon: "asset://icons/track.png", order: 2,
                          filters: [.type("b-m-t-h")]),
        ])
}
