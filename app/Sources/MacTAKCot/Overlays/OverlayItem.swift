// OverlayItem.swift — a map item as the Overlay Manager sees it (G3.11a):
// what 5.5's filter overlays and list filters read from a MapItem.
//
// - title: ATAKUtilities.getDisplayName (the item's title or callsign);
// - type: the CoT type the type filters and litmus filters test;
// - team and role: the "team" and "atakRoleType" values
//   GroupDetailHandler.toItemMetadata sets from <__group name role>;
// - author: "parent_uid", which the Self-Authored filter (AuthorFilter)
//   compares with this device's uid. LinkDetailHandler sets it from a
//   marker's <link> (any but a url link) and CreatorDetailHandler from
//   <creator>; the later detail wins, as the handlers run in the event's
//   order;
// - where it is: a point, or a line's points (a route, an R&B line), for
//   the field-of-view filter and the distance sort;
// - the R&B group: an R&B line sits in the Range & Bearing map group,
//   which Shapes lists (RangeAndBearingMapComponent).

import Foundation

public struct OverlayItem: Sendable, Equatable, Identifiable {
    public enum Location: Sendable, Equatable {
        case point(CotPoint)
        /// A line through these points, in order.
        case line([CotPoint])
    }

    /// The map group an item sits in, when it isn't the filter overlays'.
    public enum Group: Sendable, Equatable {
        case rangeAndBearing
    }

    /// The item's uid.
    public var id: String
    public var title: String
    public var type: String
    public var location: Location?
    public var team: String?
    public var role: String?
    public var author: String?
    /// <usericon iconsetpath>.
    public var iconsetPath: String?
    public var group: Group?
    /// More names a search finds it by: a route's waypoint callsigns
    /// (RouteListModel.find).
    public var searchNames: [String]

    public init(id: String, title: String, type: String, location: Location? = nil, team: String? = nil,
                role: String? = nil, author: String? = nil, iconsetPath: String? = nil, group: Group? = nil,
                searchNames: [String] = []) {
        self.id = id; self.title = title; self.type = type; self.location = location
        self.team = team; self.role = role; self.author = author; self.iconsetPath = iconsetPath
        self.group = group; self.searchNames = searchNames
    }

    /// LinkDetailHandler's RELATION_URL.
    static let urlRelation = "r-u"

    /// GroupDetailHandler's item value names.
    public static let teamKey = "team", roleKey = "atakRoleType"

    /// The item value MetaStringFilter reads.
    func value(named name: String) -> String? {
        switch name {
        case Self.teamKey: team
        case Self.roleKey: role
        default: nil
        }
    }

    /// UserIcon.IsValidIconsetPath(path, false): a well-formed iconset
    /// path that isn't one of the built-in mappings.
    var hasUserIcon: Bool {
        guard let path = iconsetPath, !path.isEmpty,
              !path.hasPrefix("COT_MAPPING_2525"), !path.hasPrefix("COT_MAPPING_SPOTMAP") else { return false }
        var tokens = path.components(separatedBy: "/")
        while tokens.last?.isEmpty == true { tokens.removeLast() }  // String.split drops trailing empties
        return tokens.count >= 2 && !tokens[0].isEmpty && !tokens[1].isEmpty
    }

    /// The point the distance sort measures from (a point item's point; a
    /// line's centre, Shape.getCenter).
    public var center: CotPoint? {
        switch location {
        case .point(let p): p
        case .line(let points): CotPoint.average(points)
        case nil: nil
        }
    }

    /// A marker's parent_uid from its event's <link> and <creator>, as
    /// the detail handlers set it, in order. (A route's <link>s are its
    /// points; its author is its <creator>.)
    public static func markerAuthor(of detail: CotDetail?) -> String? {
        var author: String?
        for child in detail?.children ?? [] {
            switch child.name {
            case "link" where child["relation"] != urlRelation:
                author = child["uid"]
            case "creator":
                author = child["uid"].flatMap { $0.isEmpty ? nil : $0 }
            default:
                continue
            }
        }
        return author
    }
}
