// ServerConnections.swift — the app's TAK servers and their connections (G3.2d).
//
// One CommoClient connects to every enabled server. The list persists as
// JSON in a key-value store (UserDefaults in the app). Certificates and
// keys live only in the IdentityStore; a ServerConfig holds their
// fingerprints. Each server's status follows commo's interface events,
// matched to the server by the endpoint id `connect` returned.
//
// The same client runs the mesh (G3.3b) when a MeshNetwork is given: it gets
// the client when commo starts, and commo's events.
//
// Who the client is comes from a SelfReporter (G3.4b): the device uid, the
// self details, the location. The client reports its self-SA on ATAK's pace.
// A profile's or package's callsign replaces the callsign, as ATAK applies
// locationCallsign.
//
// GeoChat (G3.5b) runs on the same client when a ChatStore is given: every
// CoT event goes to the ChatService too, which sends through the client.
//
// With a MapItemStore (G3.9a) the archived map items are kept across
// launches: taken back when this is made, written as they change (a
// coalesced sync after any change to the markers, lines, contacts or the
// self position, as a line's ends follow them), and written once more by
// `stop` before it clears the markers, which then stops the writing until
// `start` takes them back again.

import Combine
import Foundation
import MacTAKCot

/// Where the server list and the client's identity persist.
public protocol SettingsStore: AnyObject {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SettingsStore {}

/// A server's connection, as the app shows it.
public enum ServerStatus: Equatable, Sendable {
    case off
    case connecting
    case connected
    case failed(String)
}

@MainActor
public final class ServerConnections: ObservableObject {
    @Published public private(set) var servers: [ServerConfig] = []
    @Published public private(set) var status: [UUID: ServerStatus] = [:]
    public var uid: String { me.details.uid }
    public var callsign: String { me.details.callsign }

    public let me: SelfReporter
    /// Who this client hears, on any server or the mesh (G3.4c).
    public let contacts: ContactStore
    /// The CoT markers it hears that aren't contacts (G3.7c).
    public let markers: CotMarkerStore
    /// GeoChat, when the app gave a ChatStore (G3.5b).
    public let chat: ChatService?
    /// Range and bearing lines, made here or heard (G3.8c/d).
    public let rangeBearing = RangeBearingLines()
    /// Keeps the archived items across launches, when a store was given.
    private let archive: MapItemArchive?
    private var archiving = false
    private var archiveSyncPending = false
    private var archiveWatch: [AnyCancellable] = []
    private var detailsWatch: AnyCancellable?
    private let settings: SettingsStore
    private let identities: IdentityStore
    private let mesh: MeshNetwork?
    private var client: CommoClient?
    private var endpoints: [UUID: String] = [:]
    /// Endpoints commo reported up: an interface can come up before
    /// `connect` has handed its id back.
    private var upEndpoints: Set<String> = []
    private var listener: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    /// How often stale contacts and markers are checked for removal.
    static let expiryPeriod: Duration = .seconds(5)

    private static let serversKey = "mactak.servers"
    /// G3.2d's random uid, replaced by the device's (DeviceUID).
    private static let legacyUIDKey = "mactak.uid"

    public init(settings: SettingsStore, identities: IdentityStore, me: SelfReporter, mesh: MeshNetwork? = nil,
                chatStore: ChatStore? = nil, mapItemStore: MapItemStore? = nil) {
        self.settings = settings
        self.identities = identities
        self.me = me
        self.mesh = mesh
        let contacts = ContactStore(selfUID: me.details.uid)
        self.contacts = contacts
        markers = CotMarkerStore(selfUID: me.details.uid) { contacts[$0] != nil }
        // setAuthorInformation: production_time is a CoordinatedTime, milliseconds
        rangeBearing.author = {
            let ms = (Date().timeIntervalSince1970 * 1000).rounded(.down) / 1000
            return RangeBearingEvent.Creator(uid: me.details.uid, type: me.details.unitType,
                                             callsign: me.details.callsign, time: Date(timeIntervalSince1970: ms))
        }
        let chat = chatStore.map { ChatService(store: $0, contacts: contacts, identity: { me.chatIdentity }) }
        self.chat = chat
        archive = mapItemStore.map { MapItemArchive(store: $0, selfUID: me.details.uid) }
        // A new team or role changes which rooms take messages.
        detailsWatch = me.details.objectWillChange.sink { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { chat?.refresh() } }
        }
        settings.set(nil, forKey: Self.legacyUIDKey)
        if let data = settings.data(forKey: Self.serversKey),
           let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = decoded
        }
        for server in servers { status[server.id] = .off }
        restoreMapItems()
        let changes: [ObservableObjectPublisher] = [markers.objectWillChange, rangeBearing.objectWillChange,
                                                    contacts.objectWillChange, me.objectWillChange]
        archiveWatch = changes.map { $0.sink { [weak self] _ in self?.scheduleArchiveSync() } }
    }

    /// Starts commo, connects every enabled server, and starts the mesh.
    public func start() throws {
        guard client == nil else { return }
        if !archiving { restoreMapItems() }
        let client = try CommoClient(uid: uid, callsign: callsign)
        self.client = client
        listener = Task { [weak self] in
            for await event in client.events { self?.handle(event) }
        }
        me.attach(client)
        chat?.attach(client)
        for server in servers where server.enabled { connect(server) }
        mesh?.attach(client)
        expiry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.expiryPeriod)
                self?.contacts.expire()
                self?.markers.expire()
            }
        }
    }

    public func stop() async {
        syncArchive()
        archiving = false
        await mesh?.detach()
        me.detach()
        chat?.detach()
        expiry?.cancel()
        listener?.cancel()
        await client?.shutdown()
        client = nil
        endpoints.removeAll()
        upEndpoints.removeAll()
        for server in servers { status[server.id] = .off }
        contacts.removeAll()
        markers.removeAll()
    }

    // MARK: - the list

    public func add(_ server: ServerConfig) {
        servers.append(server)
        status[server.id] = .off
        save()
        if server.enabled { connect(server) }
    }

    public func remove(_ id: UUID) {
        disconnect(id)
        servers.removeAll { $0.id == id }
        status[id] = nil
        save()
    }

    /// Imports a data package: its certificates into the IdentityStore, its
    /// servers into the list (connected when the package enables them), and
    /// its callsign. Returns the servers added.
    @discardableResult
    public func importPackage(at url: URL) throws -> [ServerConfig] {
        let package = try DataPackage.open(url)
        let added = try identities.importServers(from: package)
        if let callsign = package.callsign { setCallsign(callsign) }
        for server in added { add(server) }
        return added
    }

    /// Imports a client certificate and a truststore for a server that has
    /// neither yet (one added by hand).
    public func importCertificates(for id: UUID, identity: (Data, String)?, truststore: (Data, String)?) throws {
        guard var server = servers.first(where: { $0.id == id }) else { return }
        if let (bytes, password) = truststore {
            server.truststore = try identities.importTruststore(pkcs12: bytes, password: password)
        }
        if let (bytes, password) = identity {
            server.identity = try identities.importIdentity(pkcs12: bytes, password: password)
        }
        replace(server)
    }

    /// ATAK's Quick Connect (G3.2e): adds the server at `address` (see
    /// ConnectString(quickConnect:)), enrolled against the public CAs, and
    /// connects it. If the enrollment fails the server is removed again, as
    /// ATAK removes its stream.
    @discardableResult
    public func quickConnect(address text: String, user: String, password: String,
                             enrollmentPort: Int = CommoClient.enrollmentPort) async throws -> ServerConfig {
        let address = try ConnectString(quickConnect: text)
        let server = ServerConfig(description: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  address: address, enabled: false, enrollForCertificate: true,
                                  enrollUseTrust: false)
        add(server)
        do {
            try await enroll(server.id, user: user, password: password, enrollmentPort: enrollmentPort)
        } catch {
            remove(server.id)
            throw error
        }
        return servers.first { $0.id == server.id } ?? server
    }

    /// Enrolls the server for a client certificate (G3.2c), applies the
    /// profile's callsign, and connects.
    public func enroll(_ id: UUID, user: String, password: String,
                       enrollmentPort: Int = CommoClient.enrollmentPort) async throws {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        let enrolling = try CommoClient(uid: uid, callsign: callsign)
        defer { Task { await enrolling.shutdown() } }
        var result = try await identities.enroll(server, user: user, password: password, using: enrolling,
                                                 port: enrollmentPort)
        if let callsign = result.profile?.callsign { setCallsign(callsign) }
        result.server.enabled = true
        replace(result.server)
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard var server = servers.first(where: { $0.id == id }), server.enabled != enabled else { return }
        server.enabled = enabled
        replace(server)
    }

    // MARK: - connections

    private func replace(_ server: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        disconnect(server.id)
        servers[index] = server
        save()
        if server.enabled { connect(server) }
    }

    private func connect(_ server: ServerConfig) {
        guard let client else { return }
        status[server.id] = .connecting
        Task {
            do {
                let transport = try server.transport(using: identities)
                let endpoint = try await client.connect(host: server.address.host, port: server.address.port,
                                                        transport: transport)
                endpoints[server.id] = endpoint
                if upEndpoints.contains(endpoint) { status[server.id] = .connected }
            } catch {
                status[server.id] = .failed("\(error)")
            }
        }
    }

    private func disconnect(_ id: UUID) {
        status[id] = .off
        guard let endpoint = endpoints.removeValue(forKey: id), let client else { return }
        Task { try? await client.disconnect(endpoint: endpoint) }
    }

    func handle(_ event: CommoEvent) {
        mesh?.handle(event)
        let server: (String) -> UUID? = { endpoint in self.endpoints.first { $0.value == endpoint }?.key }
        switch event {
        case let .interfaceUp(endpoint):
            upEndpoints.insert(endpoint)
            if let id = server(endpoint) { status[id] = .connected }
        case let .interfaceDown(endpoint):
            upEndpoints.remove(endpoint)
            if let id = server(endpoint), status[id] == .connected { status[id] = .connecting }
        case let .interfaceError(endpoint, code):
            if let id = server(endpoint) { status[id] = .failed(Self.describe(code)) }
        case let .cot(xml, endpoint):
            contacts.receive(xml, via: server(endpoint).map { .server($0) } ?? .mesh)
            markers.receive(xml)
            chat?.receive(xml)
            rangeBearing.receive(xml, isMarker: isMarker)
        case let .contactRemoved(uid):
            contacts.remove(uid)
        default:
            break
        }
    }

    /// Send the line `id` as 5.5's Send does (u-rb-a, RangeBearingEvent):
    /// to the contacts in `contacts`, or to everyone (a broadcast) when it
    /// is nil. An end tied to a CoT marker is named by its uid; one tied to
    /// a contact or this client isn't, as 5.5 doesn't. The line's creator
    /// goes with it, a received line's included.
    /// Throws when commo isn't running, the line is gone, or an end's
    /// marker has no place here.
    public func share(line id: String, to contacts: [String]? = nil, style: RangeBearing.Style,
                      at now: Date = Date()) throws {
        guard let client else { throw ShareError.notRunning }
        guard let line = rangeBearing[id] else { throw ShareError.noLine }
        guard let start = place(line.start), let end = place(line.end) else { throw ShareError.noPlace }
        let event = RangeBearingEvent.make(uid: line.id, title: line.title, start: start, end: end,
                                           startUID: namedUID(line.start), endUID: namedUID(line.end), style: style,
                                           color: line.color, weight: line.weight, archive: line.archived,
                                           creator: line.creator, now: now)
        let xml = event.xml()
        Task {
            if let contacts { try? await client.send(xml, to: contacts) } else { try? await client.broadcast(xml, via: .any) }
        }
    }

    public enum ShareError: Error, Equatable { case notRunning, noLine, noPlace }

    /// Where an end is now: its place, or its marker's, contact's or this client's.
    private func place(_ end: RangeBearingEnd) -> CotPoint? {
        switch end {
        case .point(let p): return p
        case .item(let id):
            return markers[id]?.point ?? contacts[id]?.point ?? (id == uid ? me.location?.point : nil)
        }
    }

    /// 5.5's isEndpointSerializable: only a CoT marker's uid is written.
    private func namedUID(_ end: RangeBearingEnd) -> String? {
        if case .item(let id) = end, markers[id] != nil { return id }
        return nil
    }

    /// Whether a uid is something a line's end can be tied to here: a CoT
    /// marker, a contact or this client.
    private func isMarker(_ id: String) -> Bool {
        markers[id] != nil || contacts[id] != nil || id == uid
    }

    // MARK: - kept map items

    /// Takes the kept items back through the importers (the markers, then
    /// the lines, which defer while a marker they name isn't in yet).
    private func restoreMapItems() {
        guard let archive else { return }
        archive.restore({ xml in
            let marker = markers.receive(xml)
            switch rangeBearing.restore(xml, isMarker: isMarker, selfUID: uid) {
            case .restored: return .taken
            case .deferred: return .deferred
            case .ignored: return marker ? .taken : .ignored
            }
        }, current: archivedItems)
        archiving = true
    }

    private func scheduleArchiveSync() {
        guard archiving, !archiveSyncPending else { return }
        archiveSyncPending = true
        // after the change: objectWillChange fires before it lands
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.archiveSyncPending = false
                self?.syncArchive()
            }
        }
    }

    /// Writes the archived items that changed now.
    func syncArchive() {
        guard archiving, let archive else { return }
        archive.sync(archivedItems())
    }

    /// The archived markers as they came, and the archived lines as 5.5
    /// stores them (u-rb-a, units as 5.5's defaults: a line keeps none of
    /// its own here). A line with an end that has no place right now
    /// (its contact just went) is left as last stored.
    private func archivedItems() -> [ArchivedItem] {
        let kept = markers.markers.compactMap { m in
            m.archivedEvent.map { xml in ArchivedItem(uid: m.uid, type: m.type, signature: xml) { xml } }
        }
        let lines = rangeBearing.lines.filter(\.archived).map { line -> ArchivedItem in
            guard let start = place(line.start), let end = place(line.end) else {
                return ArchivedItem(uid: line.id, type: RangeBearingEvent.type, signature: nil) { "" }
            }
            let startUID = namedUID(line.start), endUID = namedUID(line.end)
            func event(_ now: Date) -> String {
                RangeBearingEvent.make(uid: line.id, title: line.title, start: start, end: end,
                                       startUID: startUID, endUID: endUID, style: .atak,
                                       color: line.color, weight: line.weight, archive: true,
                                       creator: line.creator, now: now).xml()
            }
            return ArchivedItem(uid: line.id, type: RangeBearingEvent.type,
                                signature: event(Date(timeIntervalSince1970: 0))) { event(Date()) }
        }
        return kept + lines
    }

    private func setCallsign(_ callsign: String) {
        me.details.callsign = callsign
    }

    private func save() {
        settings.set(try? JSONEncoder().encode(servers), forKey: Self.serversKey)
    }

    /// commo's NetInterfaceErrorCode, by name (netinterface.h).
    static func describe(_ code: Int32) -> String {
        let names = ["can't resolve the host", "connection refused", "connection timed out",
                     "the host is unreachable", "the server sent no certificate",
                     "the server's certificate isn't trusted", "the TLS handshake failed",
                     "the connection failed", "no data from the server in time", "an I/O error",
                     "an internal error", "an error"]
        return names.indices.contains(Int(code)) ? names[Int(code)] : "error \(code)"
    }
}
