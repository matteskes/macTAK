// CotMarkerStore.swift — the CoT markers this client hears that aren't
// contacts (G3.7c): an atom ("a-…") event with no <contact endpoint>, which
// ATAK 5.5's marker importers (MarkerImporter: "a-h", "a-f", "a-n", "a-u"
// and the "Other" fallback) put on the map, and a Spot Map point
// (b-m-p-s-m, SpotMapImporter; G3.9b). A contact's SA belongs to the
// ContactStore: when one arrives under a marker's uid, the marker goes, and
// a uid the contacts hold is never a marker. Its own uid is dropped.
//
// An update is read as MarkerImporter reads one (G3.9d): its point, type
// and how replace the marker's, and each detail it carries replaces the
// one of that name; a detail it leaves out is kept, as 5.5's handlers
// keep the metadata they set, except <precisionlocation>, which goes with
// the old point (setPoint), and an <__address> looked up for a place the
// marker has left (AddressDetailHandler's locationHash).
//
// Stale and removal follow 5.5 (MarkerImporter, CotMarkerRefresher), timed
// by this Mac's clock from when the event arrived, as contacts are:
//   - stale 1.5 × (stale − start) after it arrived (CotEvent.autoStaleDuration)
//   - removed 5 minutes after it went stale (expireStaleItemsTime, with
//     expireEverything on, 5.5's default).
// A delete task (t-x-d-d) reaches a marker through MapItems.importDelete:
// with <__forcedelete> it is removed, otherwise `forceStale` makes it
// stale now.
//
// A marker that came with <archive/> (ArchiveDetailHandler) is kept across
// launches (G3.9a, the MapItemArchive) and, as 5.5 sets no
// autoStaleDuration on one (CotMapAdapter.isAtakSpecialType), never goes
// stale and isn't removed by time; a delete task without <__forcedelete>
// leaves it alone (the refresher skips a marker with no autoStaleDuration
// before it reads forceStale). Once archived it stays so, as the meta
// value stays when an update leaves the detail out. A Spot Map point is one
// of 5.5's special types too: never stale, archived or not, and a plain
// delete task leaves it alone the same way.
//
// Edits made here (G3.9c: the inspector, a move, a delete) change the
// marker's last event, which the marker is read from again; it keeps when
// it was heard and when it goes stale, and stays archived when it was. A
// newer event heard for it replaces the edit, as in 5.5. A delete removes
// it here only (RemoveBroadcastReceiver: nothing is sent).

import Foundation
import MacTAKCot

public struct CotMarker: Sendable, Equatable, Identifiable {
    public var id: String { uid }
    public var uid: String
    /// What 5.5 reads to pick its icon; type and how included.
    public var traits: MarkerTraits
    /// The callsign, else the uid unless it is a UUID (MarkerImporter).
    public var label: String?
    public var point: CotPoint
    /// Its looked-up street address (<__address>), kept against `point`
    /// as 5.5's AddressDetailHandler keeps it.
    public var address: AddressDetail?
    /// When its last event arrived here.
    public var lastHeard: Date
    /// When it goes stale if nothing newer arrives.
    public var staleAt: Date
    /// When it is removed if nothing newer arrives.
    public var removeAt: Date
    /// The CoT it is kept as across launches, <archive/> included; nil
    /// when it isn't kept.
    public var archivedEvent: String?
    /// Its last event, with the edits made here since.
    public var event: CotEvent

    public var archived: Bool { archivedEvent != nil }

    /// <remarks>.
    public var remarks: String? { event.remarks }

    /// Whether it can be moved (not machine generated).
    public var movable: Bool { event.isMovable }

    public var type: String { traits.type }

    public func isStale(at now: Date) -> Bool { now >= staleAt }

    /// Whether it goes stale by time: 5.5 sets no autoStaleDuration on an
    /// archived marker or a special type (Spot Map), and its refresher
    /// then skips the marker altogether.
    public var autoStales: Bool { staleAt != .distantFuture }
}

@MainActor
public final class CotMarkerStore: ObservableObject {
    /// By uid.
    @Published public private(set) var markers: [CotMarker] = []

    private let selfUID: String
    private let isContact: (String) -> Bool
    private var byUID: [String: CotMarker] = [:]

    /// `isContact` says whether the ContactStore holds a uid.
    public init(selfUID: String, isContact: @escaping (String) -> Bool) {
        self.selfUID = selfUID
        self.isContact = isContact
    }

    public subscript(uid: String) -> CotMarker? { byUID[uid] }

    /// Takes in a CoT event commo received; anything but a marker is
    /// ignored. `xml` must be the text `heard` was parsed from: an archived
    /// marker keeps that text as it came, so nothing checks the two agree.
    /// Returns whether the markers changed.
    @discardableResult
    public func receive(_ heard: CotEvent, xml: String, at now: Date = Date()) -> Bool {
        guard heard.uid != selfUID, heard.type.hasPrefix("a-") || Self.isSpotMap(heard.type) else { return false }
        if ContactStore.isContactSA(heard) || isContact(heard.uid) {
            return remove(heard.uid)
        }
        let event = Self.update(byUID[heard.uid]?.event, with: heard)
        let archivedEvent = Self.archivedEvent(event, xml: event == heard ? xml : event.xml(),
                                               wasArchived: byUID[event.uid]?.archived == true)
        let staleAt = archivedEvent != nil || Self.isSpotMap(event.type) ? .distantFuture
            : now.addingTimeInterval(event.autoStaleDuration)
        byUID[event.uid] = Self.marker(event, archivedEvent: archivedEvent, lastHeard: now, staleAt: staleAt)
        publish()
        return true
    }

    /// A delete task without <__forcedelete> (CotDeleteImporter's forceStale):
    /// the marker `uid` is stale now and is removed on the stale clock,
    /// unless it doesn't go stale by time or already is. Returns whether it
    /// changed.
    @discardableResult
    public func forceStale(_ uid: String, at now: Date) -> Bool {
        guard var marker = byUID[uid], marker.autoStales, !marker.isStale(at: now) else { return false }
        marker.staleAt = now
        marker.removeAt = now.addingTimeInterval(ContactStore.removeAfterStale)
        byUID[uid] = marker
        publish()
        return true
    }

    /// Edits the marker `uid` here: `change` edits its event, which the
    /// marker is read from again. Returns whether it changed.
    @discardableResult
    public func edit(_ uid: String, _ change: (inout CotEvent) -> Void) -> Bool {
        guard let old = byUID[uid] else { return false }
        var event = old.event
        change(&event)
        guard event != old.event else { return false }
        let archivedEvent = old.archived ? Self.archivedEvent(event, xml: event.xml(), wasArchived: true) : nil
        var marker = Self.marker(event, archivedEvent: archivedEvent, lastHeard: old.lastHeard, staleAt: old.staleAt)
        marker.removeAt = old.removeAt
        byUID[uid] = marker
        publish()
        return true
    }

    /// Removes the marker `uid` here; returns whether it was here.
    @discardableResult
    public func remove(uid: String) -> Bool { remove(uid) }

    private static func marker(_ event: CotEvent, archivedEvent: String?, lastHeard: Date, staleAt: Date) -> CotMarker {
        CotMarker(uid: event.uid, traits: traits(event), label: label(event), point: event.point,
                  address: AddressDetail(event.detail(AddressDetail.elementName)), lastHeard: lastHeard,
                  staleAt: staleAt, removeAt: staleAt.addingTimeInterval(ContactStore.removeAfterStale),
                  archivedEvent: archivedEvent, event: event)
    }

    /// Drops what has been stale long enough; the app calls it every few
    /// seconds, as ATAK's refresher runs.
    public func expire(at now: Date = Date()) {
        let before = byUID.count
        byUID = byUID.filter { now < $0.value.removeAt }
        if byUID.count != before { publish() }
    }

    public func removeAll() {
        byUID.removeAll()
        publish()
    }

    @discardableResult
    private func remove(_ uid: String) -> Bool {
        guard byUID.removeValue(forKey: uid) != nil else { return false }
        publish()
        return true
    }

    /// MarkerImporter's update: `heard`, with the details it leaves out
    /// kept from `old` (see the header).
    static func update(_ old: CotEvent?, with heard: CotEvent) -> CotEvent {
        guard let old, let oldDetails = old.detail?.children, !oldDetails.isEmpty else { return heard }
        var detail = heard.detail ?? CotDetail("detail")
        let carried = Set(detail.children.map(\.name))
        let moved = !AddressDetail.sameLocation(old.point, heard.point)
        let kept = oldDetails.filter { d in
            !carried.contains(d.name) && d.name != PrecisionLocation.elementName
                && !(moved && d.name == AddressDetail.elementName)
        }
        guard !kept.isEmpty else { return heard }
        for d in kept { detail.add(d) }
        var event = heard
        event.detail = detail
        return event
    }

    /// SpotMapImporter's types (prefix only).
    static func isSpotMap(_ type: String) -> Bool { type.hasPrefix(PointKind.spotMapType) }

    /// What an archived marker is kept as: the event as it came when it
    /// carries <archive/>, else (an update to a marker already archived)
    /// with <archive/> added; nil for a marker that isn't kept.
    static func archivedEvent(_ event: CotEvent, xml: String, wasArchived: Bool) -> String? {
        if event.detail("archive") != nil { return xml }
        guard wasArchived else { return nil }
        var kept = event
        var detail = kept.detail ?? CotDetail("detail")
        detail.add(CotDetail("archive"))
        kept.detail = detail
        return kept.xml()
    }

    /// The details 5.5's handlers keep for the icon: __group, <color argb>
    /// (else value), <status readiness>, <usericon iconsetpath>.
    static func traits(_ event: CotEvent) -> MarkerTraits {
        let color = event.detail("color").flatMap { $0["argb"].nonEmpty ?? $0["value"].nonEmpty }
        return MarkerTraits(
            type: event.type, how: event.how,
            group: GroupDetail(event.detail(GroupDetail.elementName)),
            color: color.map(androidColor),
            ready: event.detail("status")?["readiness"].map { $0.lowercased() == "true" } ?? true,
            iconsetPath: event.detail("usericon")?["iconsetpath"].nonEmpty)
    }

    /// Parsers.parseInt on a signed ARGB ("-65536"), white when it doesn't
    /// parse, as ColorDetailHandler reads it.
    static func androidColor(_ s: String) -> UInt32 {
        Int32(s.trimmingCharacters(in: .whitespaces)).map { UInt32(bitPattern: $0) } ?? MarkerIcons.white
    }

    /// The callsign; else the uid, unless it is a UUID.
    static func label(_ event: CotEvent) -> String? {
        if let callsign = event.detail("contact")?["callsign"].nonEmpty { return callsign }
        return UUID(uuidString: event.uid) == nil ? event.uid : nil
    }

    private func publish() {
        markers = byUID.values.sorted { $0.uid < $1.uid }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? { self.flatMap { $0.isEmpty ? nil : $0 } }
}
