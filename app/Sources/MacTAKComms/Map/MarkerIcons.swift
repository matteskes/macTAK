// MarkerIcons.swift — which icon a marker draws with (G3.7b, G3.7c), as
// ATAK 5.5 picks it (IconsMapAdapter.adaptMarkerIcon, then
// Icon2525cIconAdapter.adapt2525cMarkerIcon), and the colours it uses
// (teamToColor; CotMarkerRefresher for stale).
//
// The marker's <usericon iconsetpath> goes first: COT_MAPPING_SPOTMAP draws
// an atom as a dot in its affiliation's colour, a base64:// path is the icon
// itself, and anything else (2525C, a user icon set) goes on to 5.5's 2525C
// adapter, its default mapping:
//   1. readiness=false: the "damaged" icon for its affiliation;
//   2. a team member draws its role's icon, tinted with its team colour:
//      icons/roles/<role>[_human|_nogps].png, the variant from how ("h-*"
//      placed by hand, "m-g-l" no GPS); a custom role draws team.png (5.5
//      draws the role's abbreviation on it: not yet). This replaces 1.
//      Otherwise a <color> tints the icon;
//   3. else its type: icon_filters.xml (IconFilters), then its 2525C symbol,
//      then 5.5's unknown-type icon for its affiliation, untinted.
// A team member that asks to show as a symbol (displayAsSymbologyGraphic)
// skips 2. Stale: a team member's tint is GRAY, anything else DKGRAY.
//
// Not yet (5.5 has them): jumper above/below icons, the custom role's
// abbreviation, user icon sets (they fall through to 2525C, as 5.5 does when
// a set isn't installed).

import MacTAKCot

/// What 5.5 reads from a marker to pick its icon.
public struct MarkerTraits: Sendable, Equatable {
    public var type: String
    public var how: String
    public var group: GroupDetail?
    /// The <color argb> tint, as Android's signed ARGB; 0 or nil: none.
    public var color: UInt32?
    /// <status readiness>; false draws the "damaged" icon.
    public var ready: Bool
    /// <usericon iconsetpath>.
    public var iconsetPath: String?

    public init(type: String, how: String, group: GroupDetail? = nil, color: UInt32? = nil, ready: Bool = true,
                iconsetPath: String? = nil) {
        self.type = type; self.how = how; self.group = group
        self.color = color; self.ready = ready; self.iconsetPath = iconsetPath
    }
}

/// What a marker draws: an icon URI the engine loads, its ARGB tint and its size.
public struct MarkerIcon: Sendable, Equatable {
    public var uri: String
    public var color: UInt32
    public var width: Int
    public var height: Int

    public init(uri: String, color: UInt32 = MarkerIcons.white, width: Int = MarkerIcons.size, height: Int = MarkerIcons.size) {
        self.uri = uri; self.color = color; self.width = width; self.height = height
    }
}

public enum MarkerIcons {
    /// 5.5's marker icon size (Icon.Builder.setSize(32, 32)).
    public static let size = 32
    /// No tint.
    public static let white: UInt32 = 0xFFFF_FFFF
    /// A stale contact's tint (Color.GRAY).
    public static let staleContact: UInt32 = 0xFF88_8888
    /// A stale non-contact marker's tint (Color.DKGRAY).
    public static let staleMarker: UInt32 = 0xFF44_4444

    /// 5.5's teamToColor: the team colours, and Android's colour names for
    /// any other team; anything unknown is white.
    public static func teamColor(_ team: String?) -> UInt32 {
        switch team?.lowercased() {
        case "orange": 0xFFFF_7700
        case "maroon": 0xFF7F_0000
        case "purple": 0xFF7F_007F
        case "dark blue": 0xFF00_007F
        case "teal": 0xFF00_7F7F
        case "dark green": 0xFF00_7F00
        case "brown": 0xFFA0_714F
        case "cyan": 0xFF00_FFFF
        case "blue": 0xFF00_00FF
        case "green": 0xFF00_FF00
        case "red": 0xFFFF_0000
        case "magenta": 0xFFFF_00FF
        case "yellow", "rad sensor": 0xFFFF_FF00
        case "pink": 0xFFFF_1493
        case let name?: androidColor(name) ?? white
        case nil: white
        }
    }

    /// Color.parseColor's names, for a team 5.5 doesn't list.
    private static func androidColor(_ name: String) -> UInt32? {
        let names: [String: UInt32] = [
            "black": 0xFF00_0000, "darkgray": 0xFF44_4444, "gray": 0xFF88_8888, "grey": 0xFF88_8888,
            "lightgray": 0xFFCC_CCCC, "white": 0xFFFF_FFFF, "aqua": 0xFF00_FFFF, "fuchsia": 0xFFFF_00FF,
            "lime": 0xFF00_FF00, "navy": 0xFF00_0080, "olive": 0xFF80_8000, "silver": 0xFFC0_C0C0,
        ]
        return names[name]
    }

    /// The role icon 5.5 draws for a contact (Icon2525cIconAdapter: role → file).
    public static func roleIcon(role: String, customRole: String?, how: String) -> String {
        var path = "asset://icons/roles/"
        if let customRole, !customRole.isEmpty {
            path += "team"
        } else {
            switch role.lowercased() {
            case "hq": path += "hq"
            case "team lead": path += "teamlead"
            case "sniper": path += "sniper"
            case "k9": path += "k9"
            case "rto": path += "rto"
            case "medic": path += "medic"
            case "forward observer": path += "forwardobserver"
            default: path += "team"
            }
        }
        if how.hasPrefix("h-") {
            path += "_human"
        } else if how.hasPrefix("m-g-l") {
            path += "_nogps"
        }
        return path + ".png"
    }

    /// A contact's icon. `symbol` gives the icon of a CoT type's 2525C
    /// symbol, or nil when none draws.
    public static func contact(_ contact: Contact, stale: Bool, symbol: (String) -> String?) -> MarkerIcon {
        icon(MarkerTraits(type: contact.type, how: contact.how, group: contact.group), stale: stale, symbol: symbol)
    }

    /// A marker's icon, as 5.5 adapts it. `symbol` gives the icon of a CoT
    /// type's 2525C symbol, or nil when none draws.
    public static func icon(_ m: MarkerTraits, stale: Bool, symbol: (String) -> String?) -> MarkerIcon {
        let teamMember = m.group?.team != nil
        var icon = iconsetIcon(m) ?? milStd2525CIcon(m, symbol: symbol)
        if stale { icon.color = teamMember ? staleContact : staleMarker }
        return icon
    }

    /// The <usericon iconsetpath> mappings IconsMapAdapter handles itself;
    /// nil sends the marker on to the 2525C adapter.
    private static func iconsetIcon(_ m: MarkerTraits) -> MarkerIcon? {
        guard let path = m.iconsetPath else { return nil }
        if path.hasPrefix(spotMapMapping) {
            return spotMapIcon(m)
        }
        if path.hasPrefix("base64://") {
            return MarkerIcon(uri: path)
        }
        return nil
    }

    /// SpotMapIconAdapter for an atom: reference_point.png in its
    /// affiliation's colour (Color.BLUE, RED, GREEN, else YELLOW).
    private static func spotMapIcon(_ m: MarkerTraits) -> MarkerIcon? {
        guard m.type.hasPrefix("a-") else { return nil }
        let color: UInt32
        if m.type.hasPrefix("a-f") {
            color = 0xFF00_00FF
        } else if m.type.hasPrefix("a-h") {
            color = 0xFFFF_0000
        } else if m.type.hasPrefix("a-n") {
            color = 0xFF00_FF00
        } else {
            color = 0xFFFF_FF00
        }
        return MarkerIcon(uri: "asset://icons/reference_point.png", color: color)
    }

    /// Icon2525cIconAdapter.adapt2525cMarkerIcon.
    private static func milStd2525CIcon(_ m: MarkerTraits, symbol: (String) -> String?) -> MarkerIcon {
        var uri: String? = m.ready ? nil : damagedIcon(m.type)
        var color: UInt32? = nil
        if let group = m.group, group.team != nil, !group.displayAsSymbologyGraphic {
            uri = roleIcon(role: group.role, customRole: group.customRole, how: m.how)
            color = teamColor(group.team)
        } else if let tint = m.color, tint != 0 {
            color = tint
        }
        if let uri = uri ?? IconFilters.icon(forType: m.type) ?? symbol(m.type) {
            return MarkerIcon(uri: uri, color: color ?? white)
        }
        return MarkerIcon(uri: unknownTypeIcon(m.type))
    }

    /// 5.5's icon for a marker whose readiness is false, by affiliation.
    public static func damagedIcon(_ type: String) -> String {
        let suffix = type.hasPrefix("a-h") ? "_hostile"
            : type.hasPrefix("a-n") ? "_neutral"
            : type.hasPrefix("a-u") ? "_unknown" : ""
        return "asset://icons/damaged\(suffix).png"
    }

    /// The iconsetpath prefix of 5.5's Spot Map mapping (SpotMapPallet).
    public static let spotMapMapping = "COT_MAPPING_SPOTMAP"

    /// 5.5's icon for a type no symbol draws, by affiliation.
    public static func unknownTypeIcon(_ type: String) -> String {
        let suffix: String
        if type.hasPrefix("a-f") || type.hasPrefix("a-a") {
            suffix = "-f"
        } else if type.hasPrefix("a-n") {
            suffix = "-n"
        } else if ["a-h", "a-j", "a-k", "a-s"].contains(where: type.hasPrefix) {
            suffix = "-h"
        } else if type.hasPrefix("a-u") || type.hasPrefix("a-p") {
            suffix = "-u"
        } else {
            suffix = ""
        }
        return "asset://icons/unknown-type\(suffix).png"
    }
}
