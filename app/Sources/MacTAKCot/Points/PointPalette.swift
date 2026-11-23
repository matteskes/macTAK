// PointPalette.swift — the points the Point Dropper places (G3.9b) and the
// CoT they are kept as, from ATAK 5.5's palettes at the pin:
//
// - 2525C's four affiliations (Icon2525cPalletFragment) with its default
//   subtype, Ground: type a-?-G, iconsetpath
//   COT_MAPPING_2525C/<a-?>/<type>, named by genCallsign.
// - Spot Map's eleven colours (SpotMapPalletFragment): type b-m-p-s-m,
//   the colour as <color>, iconsetpath COT_MAPPING_SPOTMAP/b-m-p-s-m/<colour
//   as a signed int>, named "<abbreviation> n" by getCount.
//
// What a placed point's CoT says is PlacedPoint's.
//
// Not here (5.5 has them): the 2525C subtypes and type picker, Spot Map's
// label-only drop and custom colours, the Mission Specific, user icon set
// and vehicle palettes.

import Foundation

/// What the Point Dropper places.
public enum PointKind: Hashable, Sendable, Identifiable {
    case affiliation(Affiliation)
    case spotMap(SpotMapColor)

    public var id: String { iconsetPath }

    /// Every entry of both palettes.
    public static var all: [PointKind] {
        Affiliation.allCases.map { .affiliation($0) } + SpotMapColor.allCases.map { .spotMap($0) }
    }

    public enum Affiliation: String, CaseIterable, Sendable {
        case hostile = "a-h", friendly = "a-f", neutral = "a-n", unknown = "a-u"

        /// 5.5's button order on the 2525C palette.
        public static let paletteOrder: [Affiliation] = [.unknown, .neutral, .hostile, .friendly]

        public var name: String {
            switch self {
            case .hostile: "Hostile"
            case .friendly: "Friendly"
            case .neutral: "Neutral"
            case .unknown: "Unknown"
            }
        }
    }

    /// Spot Map's colours, in 5.5's palette order.
    public enum SpotMapColor: String, CaseIterable, Sendable {
        case white = "W", yellow = "Y", orange = "O", brown = "Br", red = "R", magenta = "P", blue = "B"
        case cyan = "Cy", green = "G", gray = "Gry", black = "Blk"

        /// The abbreviation a dot is named with.
        public var abbreviation: String { rawValue }

        /// Its ARGB, as Android's Color has it.
        public var argb: UInt32 {
            switch self {
            case .white: 0xFFFF_FFFF
            case .yellow: 0xFFFF_FF00
            case .orange: 0xFFFF_7700
            case .brown: 0xFF8B_4513
            case .red: 0xFFFF_0000
            case .magenta: 0xFFFF_00FF
            case .blue: 0xFF00_00FF
            case .cyan: 0xFF00_FFFF
            case .green: 0xFF00_FF00
            case .gray: 0xFF77_7777
            case .black: 0xFF00_0000
            }
        }

        public var name: String {
            switch self {
            case .white: "White"
            case .yellow: "Yellow"
            case .orange: "Orange"
            case .brown: "Brown"
            case .red: "Red"
            case .magenta: "Purple"
            case .blue: "Blue"
            case .cyan: "Cyan"
            case .green: "Green"
            case .gray: "Gray"
            case .black: "Black"
            }
        }
    }

    /// Spot Map's CoT type (SpotMapReceiver.SPOT_MAP_POINT_COT_TYPE).
    public static let spotMapType = "b-m-p-s-m"
    /// 5.5's 2525C mapping (Icon2525cPallet.COT_MAPPING_2525C).
    public static let mapping2525C = "COT_MAPPING_2525C"
    /// 5.5's Spot Map mapping (SpotMapPallet.COT_MAPPING_SPOTMAP).
    public static let mappingSpotMap = "COT_MAPPING_SPOTMAP"

    public var type: String {
        switch self {
        case .affiliation(let a): a.rawValue + "-G"
        case .spotMap: Self.spotMapType
        }
    }

    /// UserIcon.GetIconsetPath(mapping, group, file).
    public var iconsetPath: String {
        switch self {
        case .affiliation(let a): "\(Self.mapping2525C)/\(a.rawValue)/\(type)"
        case .spotMap(let c): "\(Self.mappingSpotMap)/\(Self.spotMapType)/\(Int32(bitPattern: c.argb))"
        }
    }

    /// MarkerCreator's colour: the dot's, else white.
    public var argb: UInt32 {
        switch self {
        case .affiliation: 0xFFFF_FFFF
        case .spotMap(let c): c.argb
        }
    }

    public var name: String {
        switch self {
        case .affiliation(let a): a.name
        case .spotMap(let c): c.name
        }
    }
}
