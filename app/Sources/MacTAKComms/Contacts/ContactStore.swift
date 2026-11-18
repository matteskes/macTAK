// ContactStore.swift — the TAK users this client hears (G3.4c).
//
// A contact is whoever sends SA: an atom ("a-…") event with a
// <contact endpoint>, as ATAK's ContactListDetailHandler takes it (a dropped
// marker has a callsign but no endpoint). Its own uid is dropped: with mesh
// loopback on, commo hands a client its own SA (G3.3a).
//
// Stale and removal follow ATAK 5.5 (MarkerImporter, CotMarkerRefresher),
// timed by this Mac's clock from when the SA arrived, so a peer with a
// skewed clock still goes stale on time:
//   - stale 1.5 × (stale − start) after its last SA (autoStaleDuration)
//   - removed 5 minutes after it went stale (expireStaleItemsTime) or when
//     commo reports the contact gone.
// A stale contact stays in the list, greyed, as ATAK greys its marker.

import Foundation

public struct Contact: Sendable, Equatable, Identifiable {
    /// How the SA arrived.
    public enum Path: Sendable, Equatable, Hashable {
        case mesh
        /// A TAK server, by its config id.
        case server(UUID)
    }

    public var id: String { uid }
    public var uid: String
    public var callsign: String
    public var type: String
    public var group: GroupDetail?
    public var point: CotPoint
    public var how: String
    public var precision: PrecisionLocation?
    public var takv: TakVersion?
    public var track: Track?
    public var battery: Int?
    /// The contact's own endpoint ("192.168.1.20:4242:tcp", or "*:-1:stcp"
    /// through a server).
    public var endpoint: String
    public var paths: Set<Path>
    /// When its last SA arrived here.
    public var lastHeard: Date
    /// When it goes stale if nothing newer arrives.
    public var staleAt: Date
    /// When it is removed if nothing newer arrives.
    public var removeAt: Date

    public func isStale(at now: Date) -> Bool { now >= staleAt }

    /// What the list calls the role: the custom role's abbreviation, the
    /// custom role, or the role.
    public var roleLabel: String? {
        guard let group else { return nil }
        return group.customRoleAbbreviation ?? group.customRole ?? group.role
    }
}

@MainActor
public final class ContactStore: ObservableObject {
    /// By callsign.
    @Published public private(set) var contacts: [Contact] = []

    /// ATAK's expireStaleItemsTime default.
    public static let removeAfterStale: TimeInterval = 5 * 60

    private let selfUID: String
    private var byUID: [String: Contact] = [:]

    public init(selfUID: String) {
        self.selfUID = selfUID
    }

    public subscript(uid: String) -> Contact? { byUID[uid] }

    /// Takes in a CoT event commo received over `path`; anything but a
    /// contact's SA is ignored. Returns whether it was one.
    @discardableResult
    public func receive(_ xml: String, via path: Contact.Path, at now: Date = Date()) -> Bool {
        guard let event = try? CotEvent.parse(xml, now: now), event.uid != selfUID, Self.isContactSA(event),
              let contact = event.detail("contact"), let endpoint = contact["endpoint"] else { return false }
        let autoStale = max(0, event.stale.timeIntervalSince(event.start) * 1.5)
        var paths = byUID[event.uid]?.paths ?? []
        paths.insert(path)
        let staleAt = now.addingTimeInterval(autoStale)
        byUID[event.uid] = Contact(
            uid: event.uid, callsign: contact["callsign"] ?? event.uid, type: event.type,
            group: GroupDetail(event.detail(GroupDetail.elementName)), point: event.point, how: event.how,
            precision: PrecisionLocation(event.detail(PrecisionLocation.elementName)),
            takv: TakVersion(event.detail("takv")), track: Track(event.detail("track")),
            battery: event.detail("status")?["battery"].flatMap(Int.init), endpoint: endpoint, paths: paths,
            lastHeard: now, staleAt: staleAt, removeAt: staleAt.addingTimeInterval(Self.removeAfterStale))
        publish()
        return true
    }

    /// Whether an event is a contact's SA: an atom with a <contact endpoint>.
    public static func isContactSA(_ event: CotEvent) -> Bool {
        event.type.hasPrefix("a-") && event.detail("contact")?["endpoint"]?.isEmpty == false
    }

    /// commo reports the contact gone.
    public func remove(_ uid: String) {
        guard byUID.removeValue(forKey: uid) != nil else { return }
        publish()
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

    private func publish() {
        contacts = byUID.values.sorted {
            $0.callsign.localizedStandardCompare($1.callsign) == .orderedAscending
        }
    }
}
