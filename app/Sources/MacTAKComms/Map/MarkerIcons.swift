// MarkerIcons.swift — which icon a marker draws with (G3.7b), as ATAK 5.5's
// Icon2525cIconAdapter.adapt2525cMarkerIcon picks it, and the colours it
// uses (teamToColor; CotMarkerRefresher for stale).
//
// A team member (an SA with a team) draws its role's icon, tinted with its
// team colour: icons/roles/<role>[_human|_nogps].png, the variant from how
// ("h-*" placed by hand, "m-g-l" no GPS). A custom role draws team.png (5.5
// draws the role's abbreviation on it: not yet). Anything else, and a team
// member that asks to show as a symbol (displayAsSymbologyGraphic), draws
// its type's 2525C symbol, or else 5.5's unknown-type icon for its
// affiliation. Stale: a team member's tint is GRAY, anything else DKGRAY.
//
// Not yet (5.5 has them): the readiness=false "damaged" icons, jumper
// above/below icons, the custom role's abbreviation.

import MacTAKCot

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
        let group = contact.group
        let teamMember = group?.team != nil
        if teamMember, group?.displayAsSymbologyGraphic != true {
            let uri = roleIcon(role: group?.role ?? GroupDetail.defaultRole, customRole: group?.customRole,
                               how: contact.how)
            return MarkerIcon(uri: uri, color: stale ? staleContact : teamColor(group?.team))
        }
        let uri = symbol(contact.type) ?? unknownTypeIcon(contact.type)
        return MarkerIcon(uri: uri, color: stale ? (teamMember ? staleContact : staleMarker) : white)
    }

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
