// CotMarkerStore.swift — the CoT markers this client hears that aren't
// contacts (G3.7c): an atom ("a-…") event with no <contact endpoint>, which
// ATAK 5.5's marker importers (MarkerImporter: "a-h", "a-f", "a-n", "a-u"
// and the "Other" fallback) put on the map, and a Spot Map point
// (b-m-p-s-m, SpotMapImporter; G3.9b). A contact's SA belongs to the
// ContactStore: when one arrives under a marker's uid, the marker goes, and
// a uid the contacts hold is never a marker. Its own uid is dropped.
//
// What each event says replaces what the last one said, detail by detail
// (5.5 keeps a detail an update leaves out; senders resend them all).
//
// Stale and removal follow 5.5 (MarkerImporter, CotMarkerRefresher), timed
// by this Mac's clock from when the event arrived, as contacts are:
//   - stale 1.5 × (stale − start) after it arrived (autoStaleDuration)
//   - removed 5 minutes after it went stale (expireStaleItemsTime, with
//     expireEverything on, 5.5's default).
// A delete task (t-x-d-d, CotDeleteImporter) for a marker removes it at once
// with <__forcedelete>, and otherwise makes it stale now
// (staleRemoteDisconnects, on by default).
//
// A marker that came with <archive/> (ArchiveDetailHandler) is kept across
// launches (G3.9a, the MapItemArchive) and, as 5.5 sets no
// autoStaleDuration on one (CotMapAdapter.isAtakSpecialType), never goes
// stale and isn't removed by time; a delete task without <__forcedelete>
// leaves it alone (the refresher skips a marker with no autoStaleDuration
// before it reads forceStale). Once archived it stays so, as the meta
// value stays when an update leaves the detail out. A Spot Map point is one
// of 5.5's special types too: never stale, archived or not.

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

    public var archived: Bool { archivedEvent != nil }

    public var type: String { traits.type }

    public func isStale(at now: Date) -> Bool { now >= staleAt }
}

@MainActor
public final class CotMarkerStore: ObservableObject {
    /// By uid.
    @Published public private(set) var markers: [CotMarker] = []

    /// 5.5's delete task type (CotDeleteEventMarshal).
    public static let deleteType = "t-x-d-d"

    private let selfUID: String
    private let isContact: (String) -> Bool
    private var byUID: [String: CotMarker] = [:]

    /// `isContact` says whether the ContactStore holds a uid.
    public init(selfUID: String, isContact: @escaping (String) -> Bool) {
        self.selfUID = selfUID
        self.isContact = isContact
    }

    public subscript(uid: String) -> CotMarker? { byUID[uid] }

    /// Takes in a CoT event commo received; anything but a marker or a delete
    /// task for one is ignored. Returns whether the markers changed.
    @discardableResult
    public func receive(_ xml: String, at now: Date = Date()) -> Bool {
        guard let event = try? CotEvent.parse(xml, now: now), event.uid != selfUID else { return false }
        if event.type == Self.deleteType {
            return delete(event, at: now)
        }
        guard event.type.hasPrefix("a-") || Self.isSpotMap(event.type) else { return false }
        if ContactStore.isContactSA(event) || isContact(event.uid) {
            return remove(event.uid)
        }
        let archivedEvent = Self.archivedEvent(event, xml: xml, wasArchived: byUID[event.uid]?.archived == true)
        let staleAt = archivedEvent != nil || Self.isSpotMap(event.type) ? .distantFuture
            : now.addingTimeInterval(max(0, event.stale.timeIntervalSince(event.start) * 1.5))
        byUID[event.uid] = CotMarker(
            uid: event.uid, traits: Self.traits(event), label: Self.label(event), point: event.point,
            address: AddressDetail(event.detail(AddressDetail.elementName)), lastHeard: now, staleAt: staleAt,
            removeAt: staleAt.addingTimeInterval(ContactStore.removeAfterStale), archivedEvent: archivedEvent)
        publish()
        return true
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

    /// CotDeleteImporter: <link uid relation type> names the item.
    private func delete(_ event: CotEvent, at now: Date) -> Bool {
        guard let link = event.detail("link"), let uid = link["uid"], !uid.isEmpty,
              link["relation"]?.isEmpty == false, link["type"]?.isEmpty == false,
              var marker = byUID[uid] else { return false }
        if event.detail("__forcedelete") != nil {
            return remove(uid)
        }
        guard !marker.archived, !marker.isStale(at: now) else { return false }
        marker.staleAt = now
        marker.removeAt = now.addingTimeInterval(ContactStore.removeAfterStale)
        byUID[uid] = marker
        publish()
        return true
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
