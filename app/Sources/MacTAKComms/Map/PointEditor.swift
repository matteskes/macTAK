// PointEditor.swift — editing the CoT markers on the map (G3.9c), what ATAK
// 5.5's radial menu and details drop-down do for a point (menus/a-?.xml,
// b-m-p-s-m.xml, CoTInfoView, SpotMapPointDetailsView), for a Mac:
//
// - a click on a marker shows it in the inspector (5.5's details), a click
//   on the map closes it;
// - the inspector edits its name, affiliation, colour and remarks, and
//   looks up its address (PointEdits says what each changes);
// - Move (5.5's fine adjust): the next click places it there, or it is
//   dragged; a machine-generated marker (how "m-g") doesn't move;
// - Delete removes it here (5.5 asks first; the app does).
//
// Every CoT marker can be edited, received ones too, as 5.5's
// MarkerImporter makes them editable and removable. Contacts and the self
// marker aren't: they have menus of their own in 5.5. Send and Range &
// Bearing from here are ServerConnections' and RangeBearingLines'.

import Foundation
import MacTAKCot

@MainActor
public final class PointEditor: ObservableObject {
    /// The marker the inspector shows; nil while it is closed.
    @Published public private(set) var inspected: String?
    /// The marker the next click moves; nil while not moving.
    @Published public private(set) var moving: String?

    private let markers: CotMarkerStore
    private let locate: (MapPick) -> SourcedPoint?

    /// `locate` says where a click is: the ground's place, or the clicked
    /// item's (marker, contact, self).
    public init(markers: CotMarkerStore, locate: @escaping (MapPick) -> SourcedPoint?) {
        self.markers = markers
        self.locate = locate
    }

    /// Whether `uid` is a marker this edits.
    public func canEdit(_ uid: String) -> Bool { markers[uid] != nil }

    /// Whether `uid` is a marker that moves.
    public func canMove(_ uid: String) -> Bool { markers[uid]?.movable == true }

    /// Shows `uid` in the inspector; nil closes it.
    public func inspect(_ uid: String?) {
        inspected = uid.flatMap { canEdit($0) ? $0 : nil }
    }

    // ---- moving -------------------------------------------------------------

    public func beginMove(_ uid: String) {
        moving = canMove(uid) ? uid : nil
    }

    public func endMove() { moving = nil }

    /// The move's prompt; nil while not moving.
    public var prompt: String? {
        moving.flatMap { markers[$0] }.map { "Click where to move \($0.label ?? "the point")." }
    }

    /// A click while moving: the marker goes to the ground clicked, or to
    /// the item clicked, and the move ends. Returns whether it moved.
    @discardableResult
    public func click(_ pick: MapPick) -> Bool {
        guard let uid = moving, pick != .item(uid), let place = locate(pick) else { return false }
        moving = nil
        return move(uid, to: place)
    }

    /// Moves `uid` to where `pick` is (a drag, or a move's click).
    @discardableResult
    public func move(_ uid: String, to pick: MapPick) -> Bool {
        guard let place = locate(pick) else { return false }
        return move(uid, to: place)
    }

    private func move(_ uid: String, to place: SourcedPoint) -> Bool {
        markers.edit(uid) { $0.move(to: place) }
    }

    // ---- the inspector's fields --------------------------------------------

    public func rename(_ uid: String, to name: String) {
        markers.edit(uid) { $0.rename(name) }
    }

    public func setRemarks(_ uid: String, _ text: String) {
        markers.edit(uid) { $0.setRemarks(text) }
    }

    public func setColor(_ uid: String, _ argb: UInt32) {
        markers.edit(uid) { $0.setColor(argb) }
    }

    public func setAffiliation(_ uid: String, _ a: PointKind.Affiliation) {
        markers.edit(uid) { $0.setAffiliation(a) }
    }

    /// Keeps `address` when it was looked up for where `uid` still is
    /// (`at`); returns whether it was kept.
    @discardableResult
    public func setAddress(_ uid: String, _ address: AddressDetail, lookedUpAt at: CotPoint) -> Bool {
        guard let m = markers[uid], AddressDetail.sameLocation(m.point, at) else { return false }
        return markers.edit(uid) { $0.setAddress(address) }
    }

    /// Removes `uid` here; the inspector and a move of it end.
    public func delete(_ uid: String) {
        markers.remove(uid: uid)
        if inspected == uid { inspected = nil }
        if moving == uid { moving = nil }
    }
}
