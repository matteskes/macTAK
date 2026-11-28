// MapItems.swift — the map's items in one place (G3 clean-code re-audit,
// N1): the contacts, the CoT markers, the R&B lines, the routes, which of
// them are hidden, and where a click or an end is (MapLocator). This client
// counts as an item too: a line's end can be tied to it.
//
// Everything that follows the items used to list the stores one by one
// (ServerConnections, the archive, the Overlay Manager, the map). It now
// asks this type, so a new kind of item joins here:
//
// - `changed` fires once after any of them changed (this client's position
//   and details included), on the main queue after the change has landed,
//   coalesced to one per turn of the queue: objectWillChange fires before
//   a change, so each follower used to defer its own work the same way;
// - `receive` hands a CoT event commo heard to each kind, `expire` and
//   `removeHeard` do the stale-time and stop work;
// - the archive (G3.9a): what is kept across launches (`archivedItems`)
//   and how a kept one comes back (`importKept`), with the events 5.5
//   writes for a line and a route, which Send uses too.

import Combine
import Foundation
import MacTAKCot

@MainActor
public final class MapItems {
    /// Who this client hears, on any server or the mesh (G3.4c).
    public let contacts: ContactStore
    /// The CoT markers it hears or places that aren't contacts (G3.7c).
    public let markers: CotMarkerStore
    /// Range and bearing lines, made here or heard (G3.8c/d).
    public let rangeBearing = RangeBearingLines()
    /// Routes, made here or heard (G3.10a).
    public let routes = Routes()
    /// Which items are hidden (G3.11b), kept across launches for the
    /// archived ones.
    public let visibility = MapVisibility()
    /// Where a click on the map is, and an item's place (G3.9d); the app
    /// gives it the engine's altitude source.
    public let locator: MapLocator
    /// Fires after any item changed; see the header.
    public var changed: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }

    private let me: SelfReporter
    private var selfUID: String { me.details.uid }
    private let changes = PassthroughSubject<Void, Never>()
    private var changePending = false
    private var watches: [AnyCancellable] = []
    /// Keeps the archived items across launches, when a store was given.
    private var archive: MapItemSync?

    /// With a `store`, the kept items come back now and are kept from then on.
    public init(me: SelfReporter, store: MapItemStore? = nil) {
        self.me = me
        let contacts = ContactStore(selfUID: me.details.uid)
        self.contacts = contacts
        markers = CotMarkerStore(selfUID: me.details.uid) { contacts[$0] != nil }
        locator = MapLocator(markers: markers, contacts: contacts, me: me)
        watches = [contacts.objectWillChange, markers.objectWillChange, rangeBearing.objectWillChange,
                   routes.objectWillChange, visibility.objectWillChange, me.objectWillChange]
            .map { $0.sink { [weak self] _ in self?.scheduleChanged() } }
        archive = store.map { store in
            MapItemSync(archive: MapItemArchive(store: store, selfUID: me.details.uid),
                        importer: { [unowned self] item in importKept(item) },
                        items: { [unowned self] in archivedItems() },
                        changed: changed)
        }
        archive?.restore()
    }

    private func scheduleChanged() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.changePending = false
                self?.changes.send()
            }
        }
    }

    // MARK: - what commo hears

    /// Hands a CoT event heard `via` a server or the mesh to each kind.
    public func receive(_ xml: String, via path: Contact.Path) {
        contacts.receive(xml, via: path)
        markers.receive(xml)
        rangeBearing.receive(xml, isMarker: isMapItem)
        routes.receive(xml, isItem: isMapItem)
    }

    /// Whether a uid is something a line's end or a route's point can be
    /// tied to here: a CoT marker, a contact or this client.
    public func isMapItem(_ uid: String) -> Bool {
        markers[uid] != nil || contacts[uid] != nil || uid == selfUID
    }

    /// Removes the contacts and markers whose time is up.
    func expire() {
        contacts.expire()
        markers.expire()
    }

    /// Forgets the contacts and markers when commo stops; the archived
    /// markers come back with the next `startKeeping`.
    func removeHeard() {
        contacts.removeAll()
        markers.removeAll()
    }

    // MARK: - the events 5.5 writes

    /// The line as 5.5 writes it (u-rb-a, RangeBearingEvent), its ends
    /// where they are now, for a style and a time; nil when an end has no
    /// place here (its contact just went).
    func lineEvent(_ line: RangeBearingLine) -> ((RangeBearing.Style, Date) -> CotEvent)? {
        guard let start = place(line.start), let end = place(line.end) else { return nil }
        let startUID = namedUID(line.start), endUID = namedUID(line.end)
        return { style, now in
            RangeBearingEvent.make(uid: line.id, title: line.title, start: start, end: end,
                                   startUID: startUID, endUID: endUID, style: style,
                                   color: line.color, weight: line.weight, archive: line.archived,
                                   creator: line.creator, now: now)
        }
    }

    /// The route as 5.5 writes it, with where its centre's altitude comes from.
    func routeEvent(_ route: Route, at now: Date) -> CotEvent {
        RouteEvent.make(route, center: route.center.map(locator.elevationSource), now: now)
    }

    /// Where an end is now: its place, or its marker's, contact's or this client's.
    private func place(_ end: RangeBearingEnd) -> CotPoint? {
        switch end {
        case .point(let p): return p
        case .item(let id):
            return markers[id]?.point ?? contacts[id]?.point ?? (id == selfUID ? me.location?.point : nil)
        }
    }

    /// 5.5's isEndpointSerializable: only a CoT marker's uid is written.
    private func namedUID(_ end: RangeBearingEnd) -> String? {
        if case .item(let id) = end, markers[id] != nil { return id }
        return nil
    }

    // MARK: - kept across launches

    /// Whether the archived items are being kept.
    var isKeeping: Bool { archive?.isKeeping ?? false }

    /// Takes the kept items back again after `suspendKeeping`.
    func startKeeping() {
        if archive?.isKeeping == false { archive?.restore() }
    }

    /// Writes once more, then stops keeping until `startKeeping`.
    func suspendKeeping() { archive?.suspend() }

    /// Writes the archived items that changed now.
    func syncArchive() { archive?.sync() }

    /// Takes one kept item back through the importers: the markers, the
    /// routes, then the lines, which defer while a marker they name isn't
    /// in yet. Each takes the row's `visible` as 5.5's importers take the
    /// StateSaver's extra: a marker always (MarkerImporter), a route as a
    /// shape, its points with it (DrawingImporter), a line when it is
    /// first added (RangeAndBearingImporter), which a kept one is.
    private func importKept(_ kept: StoredMapItem) -> MapItemArchive.Import {
        let xml = kept.event
        let marker = markers.receive(xml)
        if marker { visibility.set(kept.uid, visible: kept.visible) }
        if routes.restore(xml, isItem: isMapItem, selfUID: selfUID) == .restored {
            if let route = routes[kept.uid], visibility.isVisible(route.id) != kept.visible {
                visibility.set([route.id] + route.points.map(\.uid), visible: kept.visible)
            }
            return .taken
        }
        switch rangeBearing.restore(xml, isMarker: isMapItem, selfUID: selfUID) {
        case .restored:
            visibility.set(kept.uid, visible: kept.visible)
            return .taken
        case .deferred: return .deferred
        case .ignored: return marker ? .taken : .ignored
        }
    }

    /// The archived markers as they came, the routes as 5.5 writes them,
    /// and the archived lines as 5.5 stores them (u-rb-a, units as 5.5's
    /// defaults: a line keeps none of its own here). A line with an end
    /// that has no place right now (its contact just went) is left as last
    /// stored.
    private func archivedItems() -> [ArchivedItem] {
        let kept = markers.markers.compactMap { m in
            m.archivedEvent.map { xml in
                ArchivedItem(uid: m.uid, type: m.type, signature: xml, visible: visibility.isVisible(m.uid)) { xml }
            }
        }
        let lines = rangeBearing.lines.filter(\.archived).map { line -> ArchivedItem in
            guard let event = lineEvent(line) else {
                return ArchivedItem(uid: line.id, type: RangeBearingEvent.type, signature: nil) { "" }
            }
            return ArchivedItem(uid: line.id, type: RangeBearingEvent.type,
                                signature: event(.atak, Date(timeIntervalSince1970: 0)).xml(),
                                visible: visibility.isVisible(line.id)) { event(.atak, Date()).xml() }
        }
        // the centre's altitude source is looked up only when a route is written
        // a route the tool is still drawing, under two points, isn't kept: 5.5
        // removes it if the tool ends there (RouteEditTool.onToolEnd)
        let keptRoutes = routes.routes.filter { $0.archived && $0.points.count >= 2 }.map { route in
            ArchivedItem(uid: route.id, type: Route.type,
                         signature: RouteEvent.make(route, center: nil, now: Date(timeIntervalSince1970: 0)).xml(),
                         visible: visibility.isVisible(route.id)) {
                self.routeEvent(route, at: Date()).xml()
            }
        }
        return kept + lines + keptRoutes
    }
}
