// CommoClient.swift — a TAK client's connection to its servers (G3.1).
//
// Swift over commo through CCommoShim (commo_shim.h). One CommoClient is one
// commo instance: one identity (uid, callsign) with any number of server
// connections. What commo reports (CoT, contacts, interface changes, its log)
// arrives on `events`, from commo's threads, in order per source.
//
// The send rules G1 found (dev/g1/NOTES.md §Round-trip contract) hold here:
// a server registers a client only after its first self-SA, and does not
// echo a client's own events back to it. And commo reports an interface up
// before it can send on it (G1: a broadcast from the interfaceUp callback
// is accepted and goes nowhere), so the beacon waits `sendableDelay` after
// each interface comes up.

import CCommoShim
import Foundation

/// Which of commo's interfaces a broadcast goes out on.
public enum SendRoute: Sendable {
    /// TAK servers only (ATAK's reliable stream).
    case server
    /// The mesh only (the unreliable stream).
    case mesh
    case any

    var method: Int32 {
        switch self {
        case .server: Int32(MACTAK_COMMO_SEND_SERVER)
        case .mesh: Int32(MACTAK_COMMO_SEND_MESH)
        case .any: Int32(MACTAK_COMMO_SEND_ANY)
        }
    }
}

public enum CommoTransport: Sendable {
    case tcp
    /// TLS over TCP, with a client certificate (a TAK server's port 8089).
    case ssl(TLSCredentials)
    /// TLS over QUIC (ALPN "takstream"), with a client certificate.
    case quic(TLSCredentials)

    var kind: Int32 {
        switch self {
        case .tcp: Int32(MACTAK_COMMO_TCP)
        case .ssl: Int32(MACTAK_COMMO_SSL)
        case .quic: Int32(MACTAK_COMMO_QUIC)
        }
    }

    var credentials: TLSCredentials? {
        switch self {
        case .tcp: nil
        case let .ssl(credentials), let .quic(credentials): credentials
        }
    }
}

/// A client identity and the CA it trusts, as commo takes them: PKCS#12
/// bytes and their passwords, in memory.
public struct TLSCredentials: Sendable {
    public var identity: Data
    public var identityPassword: String
    public var ca: Data
    public var caPassword: String

    public init(identity: Data, identityPassword: String, ca: Data, caPassword: String) {
        self.identity = identity
        self.identityPassword = identityPassword
        self.ca = ca
        self.caPassword = caPassword
    }
}

public enum CommoLogLevel: Int32, Sendable, Comparable {
    case verbose = 0, debug, warning, info, error   // commo's order
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum CommoEvent: Sendable, Equatable {
    case log(level: CommoLogLevel, message: String)
    /// One inbound CoT event, as received; endpoint is its interface.
    case cot(xml: String, endpoint: String)
    case contactAdded(uid: String)
    case contactRemoved(uid: String)
    case interfaceUp(endpoint: String)
    case interfaceDown(endpoint: String)
    /// code is commo's NetInterfaceErrorCode.
    case interfaceError(endpoint: String, code: Int32)
}

public struct CommoError: Error, CustomStringConvertible {
    public let description: String
}

public actor CommoClient {
    /// How long after an interface comes up commo can send on it.
    public static let sendableDelay: Duration = .milliseconds(500)

    public nonisolated let uid: String
    public nonisolated let events: AsyncStream<CommoEvent>

    private var handle: OpaquePointer?
    let sink: EventSink
    private let interfaceUps: AsyncStream<Void>
    private var selfReport: SelfEvent
    /// The mesh, while it runs (CommoClient+Mesh.swift).
    var mesh: MeshState?
    private var reporting: ReportingRate?
    private var reportTasks: [Task<Void, Never>] = []

    /// A commo instance identified as uid and callsign. Log lines below
    /// logLevel are dropped before they reach `events`.
    public init(uid: String, callsign: String, logLevel: CommoLogLevel = .warning) throws {
        try CommoClient.initLibraries()
        let (events, eventsOut) = AsyncStream<CommoEvent>.makeStream()
        let (ups, upsOut) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let sink = EventSink(events: eventsOut, interfaceUps: upsOut, logLevel: logLevel)
        var callbacks = EventSink.callbacks
        callbacks.context = Unmanaged.passUnretained(sink).toOpaque()
        let created = try CommoClient.call { err, len in
            uid.withCString { u in
                callsign.withCString { c in mactak_commo_create(u, c, &callbacks, err, len) }
            }
        }
        self.uid = uid
        self.events = events
        self.sink = sink
        self.interfaceUps = ups
        self.handle = created
        self.selfReport = SelfEvent(uid: uid, callsign: callsign)
    }

    deinit {
        // No callback runs once destroy returns, so the sink outlives them.
        if let handle { mactak_commo_destroy(handle) }
        sink.finish()
    }

    /// Connect to a TAK server's streaming port. commo keeps reconnecting
    /// until `disconnect`. Returns the interface's endpoint id, which the
    /// interface events carry.
    @discardableResult
    public func connect(host: String, port: Int, transport: CommoTransport = .tcp) throws -> String {
        let commo = try live()
        let kind = transport.kind
        return try CommoClient.endpoint { out, count, err, len in
            guard let tls = transport.credentials else {
                return mactak_commo_add_streaming(commo, kind, host, Int32(port),
                                                  nil, 0, nil, 0, nil, nil, out, count, err, len)
            }
            return tls.identity.withUnsafeBytes { id in
                tls.ca.withUnsafeBytes { caBytes in
                    mactak_commo_add_streaming(
                        commo, kind, host, Int32(port),
                        id.bindMemory(to: UInt8.self).baseAddress, id.count,
                        caBytes.bindMemory(to: UInt8.self).baseAddress, caBytes.count,
                        tls.identityPassword, tls.caPassword,
                        out, count, err, len)
                }
            }
        }
    }

    public func disconnect(endpoint: String) throws {
        let commo = try live()
        try CommoClient.check { err, len in mactak_commo_remove_streaming(commo, endpoint, err, len) }
    }

    /// Queue a CoT event for every connected server and mesh interface, or
    /// only those `route` names.
    public func broadcast(_ xml: String, via route: SendRoute = .any) throws {
        let commo = try live()
        try CommoClient.check { err, len in mactak_commo_broadcast(commo, xml, route.method, err, len) }
    }

    /// Queue a CoT event for the contacts with these uids.
    public func send(_ xml: String, to uids: [String]) throws {
        let commo = try live()
        var cStrings = uids.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        try cStrings.withUnsafeMutableBufferPointer { buf in
            try buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                try CommoClient.check { err, len in mactak_commo_send(commo, p, buf.count, xml, err, len) }
            }
        }
    }

    /// The self-SA as it goes out next. Its uid stays the client's. A
    /// change ATAK reports at once (callsign, team, role, custom role,
    /// unit type, remarks) is reported on the next tick.
    public var selfEvent: SelfEvent { selfReport }

    public func updateSelf(_ change: @Sendable (inout SelfEvent) -> Void) {
        var next = selfReport
        change(&next)
        next.uid = uid
        if !next.sameIdentity(as: selfReport) { reporting?.reportAsap() }
        selfReport = next
    }

    /// The callsign the self-SA carries from the next report on.
    public func setCallsign(_ callsign: String) {
        updateSelf { $0.callsign = callsign }
    }

    /// Where the self-SA says this client is, and how it knows.
    public func setLocation(_ location: SelfEvent.Location?) {
        updateSelf { $0.location = location }
    }

    public func setReportingSettings(_ settings: ReportingRate.Settings) {
        reporting?.settings = settings
    }

    /// Report the self-SA as ATAK paces it (ReportingRate): reliable to
    /// servers, unreliable to the mesh, checked every second. Both report
    /// once more `sendableDelay` after an interface comes up, so a server
    /// or peer registers this client promptly.
    public func startReporting(_ settings: ReportingRate.Settings = .atak) {
        guard reportTasks.isEmpty else { return }
        reporting = ReportingRate(settings)
        let ups = interfaceUps
        reportTasks.append(Task { [weak self] in
            for await _ in ups {
                try? await Task.sleep(for: CommoClient.sendableDelay)
                guard !Task.isCancelled else { return }
                await self?.reportAsap()
            }
        })
        reportTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: CommoClient.reportTick)
            }
        })
    }

    /// Stop reporting, disconnect everything and end `events`.
    public func shutdown() {
        reportTasks.forEach { $0.cancel() }
        reportTasks = []
        reporting = nil
        if let handle {
            mactak_commo_destroy(handle)
            self.handle = nil
        }
        sink.finish()
    }

    static let reportTick: Duration = .seconds(1)

    private func reportAsap() {
        reporting?.reportAsap()
        tick()
    }

    private func tick() {
        guard handle != nil, var rate = reporting else { return }
        let altitude = selfReport.location?.point.validAltitude
        let now = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        let due = rate.tick(now: now, altitude: altitude, speed: selfReport.track.speed)
        reporting = rate
        for report in due {
            let xml = selfReport.event(stale: TimeInterval(report.staleMillis) / 1000).xml()
            do {
                try broadcast(xml, via: report.stream == .reliable ? .server : .mesh)
            } catch {
                sink.yield(.log(level: .error, message: "self-SA not sent: \(error)"))
            }
        }
    }

    func live() throws -> OpaquePointer {
        guard let handle else { throw CommoError(description: "commo is shut down") }
        return handle
    }

    static func initLibraries() throws {
        try check { err, len in mactak_commo_init_libraries(err, len) }
    }

    /// What commo's interface error code (CommoEvent.interfaceError) means.
    static func describeInterfaceError(_ code: Int32) -> String {
        mactak_commo_interface_error_text(code).map { String(cString: $0) } ?? "error \(code)"
    }

    /// Run a shim call that reports failure as nonzero plus a message.
    static func check(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        let (rc, message) = withText(body)
        if rc != 0 { throw CommoError(description: message) }
    }

    /// Run a shim call that reports failure as NULL plus a message.
    private static func call(_ body: (UnsafeMutablePointer<CChar>, Int) -> OpaquePointer?) throws -> OpaquePointer {
        let (result, message) = withText(body)
        guard let result else { throw CommoError(description: message) }
        return result
    }

    /// Run a shim call that writes an interface id; returns the id.
    static func endpoint(
        _ body: (UnsafeMutablePointer<CChar>, Int, UnsafeMutablePointer<CChar>, Int) -> Int32
    ) throws -> String {
        try withText { out, count in try check { err, len in body(out, count, err, len) } }.text
    }

    /// Room for the text a shim call writes back: an error message or an
    /// interface id.
    private static let textCapacity = 512

    /// Run body with a buffer for the shim to write text into; returns
    /// body's result and the text.
    private static func withText<Result>(
        _ body: (UnsafeMutablePointer<CChar>, Int) throws -> Result
    ) rethrows -> (result: Result, text: String) {
        var buffer = [CChar](repeating: 0, count: textCapacity)
        return try buffer.withUnsafeMutableBufferPointer { buf in
            let result = try body(buf.baseAddress!, buf.count)
            return (result, String(cString: buf.baseAddress!))
        }
    }
}

/// Where commo's callbacks land: commo's threads, so only thread-safe parts
/// (the streams' continuations, which may be called from any thread, and the
/// enrollments' waiters, under a lock).
final class EventSink: @unchecked Sendable {
    private let events: AsyncStream<CommoEvent>.Continuation
    private let interfaceUps: AsyncStream<Void>.Continuation
    private let logLevel: CommoLogLevel
    private let lock = NSLock()
    private var enrollments: [Int32: CheckedContinuation<EnrolledIdentity, Error>] = [:]
    private var finished = false

    init(events: AsyncStream<CommoEvent>.Continuation,
         interfaceUps: AsyncStream<Void>.Continuation, logLevel: CommoLogLevel) {
        self.events = events
        self.interfaceUps = interfaceUps
        self.logLevel = logLevel
    }

    func yield(_ event: CommoEvent) {
        if case .interfaceUp = event { interfaceUps.yield() }
        if case let .log(level, _) = event, level < logLevel { return }
        events.yield(event)
    }

    func finish() {
        events.finish()
        interfaceUps.finish()
        let waiting = lock.withLock { () -> [CheckedContinuation<EnrolledIdentity, Error>] in
            finished = true
            defer { enrollments.removeAll() }
            return Array(enrollments.values)
        }
        for waiter in waiting { waiter.resume(throwing: CommoError(description: "commo shut down during enrollment")) }
    }

    /// Waits for enrollment `id` to end; `start` runs once the waiter is in
    /// place, so no update can arrive before it.
    func awaitEnrollment(_ id: Int32, start: () throws -> Void) async throws -> EnrolledIdentity {
        try await withCheckedThrowingContinuation { continuation in
            let open = lock.withLock { () -> Bool in
                if !finished { enrollments[id] = continuation }
                return !finished
            }
            guard open else {
                continuation.resume(throwing: CommoError(description: "commo is shut down"))
                return
            }
            do { try start() } catch { endEnrollment(id, .failure(error)) }
        }
    }

    /// Resumes enrollment `id`'s waiter, once; later calls do nothing.
    func endEnrollment(_ id: Int32, _ result: Result<EnrolledIdentity, Error>) {
        let waiter = lock.withLock { enrollments.removeValue(forKey: id) }
        waiter?.resume(with: result)
    }

    private static func from(_ context: UnsafeMutableRawPointer?) -> EventSink {
        Unmanaged<EventSink>.fromOpaque(context!).takeUnretainedValue()
    }

    private static func text(_ s: UnsafePointer<CChar>?) -> String {
        s.map { String(cString: $0) } ?? ""
    }

    /// The shim's callback table; the caller sets `context` to the sink.
    static let callbacks: mactak_commo_callbacks = {
        var cb = mactak_commo_callbacks()
        cb.log = { ctx, level, message in
            from(ctx).yield(.log(level: CommoLogLevel(rawValue: level) ?? .error, message: text(message)))
        }
        cb.cot_received = { ctx, xml, endpoint in
            from(ctx).yield(.cot(xml: text(xml), endpoint: text(endpoint)))
        }
        cb.contact_added = { ctx, uid in from(ctx).yield(.contactAdded(uid: text(uid))) }
        cb.contact_removed = { ctx, uid in from(ctx).yield(.contactRemoved(uid: text(uid))) }
        cb.interface_up = { ctx, endpoint in from(ctx).yield(.interfaceUp(endpoint: text(endpoint))) }
        cb.interface_down = { ctx, endpoint in from(ctx).yield(.interfaceDown(endpoint: text(endpoint))) }
        cb.interface_error = { ctx, endpoint, code in
            from(ctx).yield(.interfaceError(endpoint: text(endpoint), code: code))
        }
        cb.enrollment_update = { ctx, id, step, status, info, identity, identityCount, ca, caCount in
            let update = EnrollmentUpdate(step: step, status: status, info: text(info))
            guard let outcome = update.outcome(identity: identity.map { Data(bytes: $0, count: identityCount) },
                                               ca: ca.map { Data(bytes: $0, count: caCount) }) else { return }
            from(ctx).endEnrollment(id, outcome)
        }
        return cb
    }()
}
