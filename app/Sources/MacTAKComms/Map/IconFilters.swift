// IconFilters.swift — ATAK 5.5's filters/icon_filters.xml (G3.7c): the icon
// a CoT type draws before its 2525C symbol is tried.
//
// Icon2525cIconAdapter.lookupFromFilter matches with FiltersConfig's
// StringStartsWithComparator, and lookupFilter keeps the LAST entry that
// matches, so a longer type listed after a shorter one wins
// ("b-m-p-s-p-i" over "b"). The table is 5.5's, in its order;
// IconFiltersTests holds it to the copy in dev/g3/test/icon-filters.
//
// Only the icons an atom ("a-…") can reach ship in the engine's assets:
// the app draws received atoms (CotMarkerStore), not 5.5's b-/u- items,
// apart from a route's waypoints (b-m-p-w's gugpgpow, G3.10b).

public enum IconFilters {
    /// (type prefix, asset path), as 5.5 lists them.
    public static let entries: [(type: String, icon: String)] = [
        ("b", "icons/b.png"),
        ("b-i", "icons/document.png"),
        ("b-i-x-i", "icons/b-i-x-i.png"),
        ("b-a-g", "icons/alarm-geophysical.png"),
        ("b-a-o-opn", "icons/alarm-open.png"),
        ("b-a-o-pan", "icons/alarm-panic.png"),
        ("b-a-o-tbl", "icons/alarm-trouble.png"),
        ("u-d-z-c-c", "icons/reference_point.png"),
        ("u-r-b-c-c", "icons/reference_point.png"),
        ("u-r-b-bullseye", "icons/no_icon.png"),
        ("u-d-c-c", "icons/reference_point.png"),
        ("b-m-p-s-p-i", "icons/b-m-p-s-p-i.png"),
        ("b-m-p-s-p-loc", "icons/sensor_location.png"),
        ("b-m-p-s-p-op", "icons/binos.png"),
        ("b-m-p-a", "icons/aimpoint.png"),
        ("b-m-p-c-z", "icons/blacktriangle.png"),
        ("b-m-p-w", "icons/gugpgpow------.png"),
        ("b-m-p-c-ip", "icons/piicon_initial.png"),
        ("b-m-p-c-cp", "icons/piicon_contact.png"),
        ("b-m-p-s-m", "icons/reference_point.png"),
        ("t-k-d", "icons/ninelineicon.png"),
        ("b-m-p-j-basic", "icons/dip.png"),
        ("b-m-p-j-dip", "icons/dip.png"),
        ("b-m-p-j-alt", "icons/alt_dip.png"),
        ("b-m-p-j-alt-yellow", "icons/alt_dip.png"),
        ("b-m-p-j-alt-green", "icons/alt_dip_green.png"),
        ("b-m-p-j-alt-gray", "icons/alt_dip_gray.png"),
        ("b-m-p-j-open", "icons/open.png"),
        ("b-m-p-j-prp", "icons/reference_point.png"),
        ("b-m-p-j-virtual-dz", "icons/virtual_dz.png"),
        ("b-m-p-j-last-out", "icons/redlight.png"),
        ("b-m-p-j-height-marker", "icons/reference_point.png"),
        ("b-m-p-j-height-marker-yellow", "icons/height_marker_yellow.png"),
        ("b-m-p-j-height-marker-red", "icons/height_marker_red.png"),
        ("b-m-p-j-harp", "icons/stoplight.png"),
        ("b-m-p-j-height-marker-gone", "icons/no_icon.png"),
        ("b-m-p-j-harp-ring", "icons/no_icon.png"),
        ("b-m-p-j-wind", "icons/b.png"),
        ("b-m-p-j-lp", "icons/reference_point.png"),
        ("b-m-p-w-GOTO", "icons/green_flag.png"),
        ("b-r-f-h-c", "icons/damaged.png"),
        ("t-s", "icons/b.png"),
        ("inv_waypoint", "icons/cornerpoint.png"),
        ("vsd-marker", "icons/viewshed_eye.png"),
        ("u-X", "icons/reference_point.png"),
        ("u-d-p", "icons/reference_point.png"),
        ("u-o-p", "icons/reference_point.png"),
        ("line_marker", "icons/reference_point.png"),
        ("end_u-o-r", "icons/reference_point.png"),
        ("center_", "icons/reference_point.png"),
        ("crit_marker", "icons/reference_point.png"),
        ("line_corner", "icons/reference_point.png"),
        ("square_corner", "icons/reference_point.png"),
        ("square_marker", "icons/reference_point.png"),
        ("corner_", "icons/cornerpoint.png"),
        ("side_", "icons/middlepoint.png"),
        ("shape_marker", "icons/reference_point.png"),
        ("a-h-G-E-S-t", "icons/ttl-icon.png"),
        ("a-f-G-E-S-t", "icons/ttl-icon-f.png"),
        ("a-u-G-E-S-t", "icons/ttl-icon-u.png"),
        ("a-n-G-E-S-t", "icons/ttl-icon-n.png"),
        ("a-f-G-I-U-exp", "icons/green_flag.png"),
        ("stack", "icons/cas_stack.png"),
    ]

    /// The asset:// icon 5.5's filters give `type`, or nil.
    public static func icon(forType type: String) -> String? {
        entries.last { type.hasPrefix($0.type) }.map { "asset://" + $0.icon }
    }
}
