// PointEdits.swift — what editing a point changes in its CoT (G3.9c), as
// ATAK 5.5's details views and move tools change the marker that CoT is
// written from (CoTInfoView, GenericPointDetailsView, fine adjust):
//
// - the name is <contact callsign>; one that is empty or the uid is
//   ignored (_updateName);
// - the affiliation swaps the type's second letter, for an atom ("a-…")
//   that isn't machine generated (how "m-g"); its iconsetpath is left as
//   it was, as 5.5 leaves the meta value;
// - the colour is <color argb>, from 5.5's ColorPalette, for a 2525C
//   point and a Spot Map dot alike;
// - the remarks are <remarks>' text, trimmed;
// - the address is <__address> (AddressDetailHandler), looked up for where
//   the point is;
// - a move sets the point and where it came from (<precisionlocation>, as
//   the marker's GeoPointMetaData is replaced); a machine-generated marker
//   isn't movable. An address looked up for somewhere else is no longer
//   sent (AddressDetailHandler's locationHash), so it goes.

import Foundation

/// 5.5's ColorPalette: the colours a point's colour button offers.
public enum PointColors {
    public static let palette: [UInt32] = [
        0xFFFF_FFFF, 0xFFFF_FF00, 0xFFFF_7700, 0xFFFF_00FF, 0xFFFF_0000,
        0xFF7F_0000, 0xFF7F_007F, 0xFF00_007F, 0xFF00_00FF, 0xFF00_FFFF,
        0xFF00_7F7F, 0xFF00_FF00, 0xFF00_7F00, 0xFF77_7777, 0xFF00_0000,
    ]
}

extension CotEvent {
    /// MarkerImporter: "m-g" marks a machine-generated marker, which isn't moved.
    public static let machineGenerated = "m-g"

    /// Whether a move applies (MarkerImporter's movable).
    public var isMovable: Bool { how != Self.machineGenerated }

    /// Whether the affiliation can change (CoTInfoView's icon button).
    public var hasEditableAffiliation: Bool { type.hasPrefix("a-") && type.count >= 3 && isMovable }

    /// The affiliation its type says, for an atom of one of the four.
    public var affiliation: PointKind.Affiliation? {
        PointKind.Affiliation.allCases.first { type.hasPrefix($0.rawValue) }
    }

    /// The <contact callsign>; returns whether it changed.
    @discardableResult
    public mutating func rename(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != uid else { return false }
        var contact = detail("contact") ?? CotDetail("contact")
        guard contact["callsign"] != name else { return false }
        contact["callsign"] = name
        replaceDetail(contact)
        return true
    }

    /// <remarks>: the text trimmed; empty removes it.
    public mutating func setRemarks(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return removeDetails("remarks") }
        var remarks = detail("remarks") ?? CotDetail("remarks")
        remarks.innerText = text
        replaceDetail(remarks)
    }

    /// The <remarks> text, if any.
    public var remarks: String? { detail("remarks")?.innerText }

    /// <color argb>, as Android's signed int.
    public mutating func setColor(_ argb: UInt32) {
        var color = detail("color") ?? CotDetail("color")
        color["argb"] = String(argb.androidColor)
        color["value"] = nil
        replaceDetail(color)
    }

    /// "a-?" + the rest of the type; ignored where it can't change.
    public mutating func setAffiliation(_ a: PointKind.Affiliation) {
        guard hasEditableAffiliation else { return }
        type = a.rawValue + type.dropFirst(3)
    }

    /// <__address>, looked up for where the point is now.
    public mutating func setAddress(_ address: AddressDetail) {
        replaceDetail(address.detail)
    }

    /// The <__address>, if any.
    public var address: AddressDetail? { AddressDetail(detail(AddressDetail.elementName)) }

    /// The point and its <precisionlocation>, for a marker that moves.
    public mutating func move(to place: SourcedPoint) {
        guard isMovable, place.point.isValid else { return }
        if !AddressDetail.sameLocation(point, place.point) { removeDetails(AddressDetail.elementName) }
        point = CotPoint(mapPoint: place.point)
        removeDetails(PrecisionLocation.elementName)
        if let precision = place.precision?.detail { replaceDetail(precision) }
    }

    /// Takes out every detail named `name`.
    mutating func removeDetails(_ name: String) {
        detail?.children.removeAll { $0.name == name }
    }

    /// Puts `child` in place of the detail with its name, or adds it.
    private mutating func replaceDetail(_ child: CotDetail) {
        var d = detail ?? CotDetail("detail")
        if let i = d.children.firstIndex(where: { $0.name == child.name }) {
            d.children[i] = child
        } else {
            d.add(child)
        }
        detail = d
    }
}
