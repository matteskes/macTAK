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

public enum CommoTransport: Sendable {
    case tcp
    /// TLS with a client certificate: the identity and the CA as PKCS#12.
    case ssl(identity: Data, identityPassword: String, ca: Data, caPassword: String)
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
    private let sink: EventSink
    private let interfaceUps: AsyncStream<Void>
    private var presence: Presence
    private var beaconTasks: [Task<Void, Never>] = []

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
        self.presence = Presence(uid: uid, callsign: callsign)
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
        var endpoint = [CChar](repeating: 0, count: 512)
        let endpointCount = endpoint.count
        try endpoint.withUnsafeMutableBufferPointer { out in
            try CommoClient.check { err, len in
                switch transport {
                case .tcp:
                    return mactak_commo_add_streaming(commo, Int32(MACTAK_COMMO_TCP), host, Int32(port),
                                                      nil, 0, nil, 0, nil, nil,
                                                      out.baseAddress, endpointCount, err, len)
                case let .ssl(identity, identityPassword, ca, caPassword):
                    return identity.withUnsafeBytes { id in
                        ca.withUnsafeBytes { caBytes in
                            mactak_commo_add_streaming(
                                commo, Int32(MACTAK_COMMO_SSL), host, Int32(port),
                                id.bindMemory(to: UInt8.self).baseAddress, id.count,
                                caBytes.bindMemory(to: UInt8.self).baseAddress, caBytes.count,
                                identityPassword, caPassword,
                                out.baseAddress, endpointCount, err, len)
                        }
                    }
                }
            }
        }
        return String(cString: endpoint)
    }

    public func disconnect(endpoint: String) throws {
        let commo = try live()
        try CommoClient.check { err, len in mactak_commo_remove_streaming(commo, endpoint, err, len) }
    }

    /// Queue a CoT event for every connected server.
    public func broadcast(_ xml: String) throws {
        let commo = try live()
        try CommoClient.check { err, len in mactak_commo_broadcast(commo, xml, err, len) }
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

    /// Where the beacon says this client is.
    public func setPosition(_ position: Presence.Position?) {
        presence.position = position
    }

    /// Beacon self-SA every period, and once more `sendableDelay` after each
    /// interface comes up, so a server registers this client promptly.
    public func startBeacon(every period: Duration = .seconds(5)) {
        guard beaconTasks.isEmpty else { return }
        let ups = interfaceUps
        beaconTasks.append(Task { [weak self] in
            for await _ in ups {
                try? await Task.sleep(for: CommoClient.sendableDelay)
                guard !Task.isCancelled else { return }
                await self?.sendPresence()
            }
        })
        beaconTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: period)
                guard !Task.isCancelled else { return }
                await self?.sendPresence()
            }
        })
    }

    /// Stop the beacon, disconnect everything and end `events`.
    public func shutdown() {
        beaconTasks.forEach { $0.cancel() }
        beaconTasks = []
        if let handle {
            mactak_commo_destroy(handle)
            self.handle = nil
        }
        sink.finish()
    }

    private func sendPresence() {
        guard handle != nil else { return }
        do {
            try broadcast(presence.xml())
        } catch {
            sink.yield(.log(level: .error, message: "presence not sent: \(error)"))
        }
    }

    private func live() throws -> OpaquePointer {
        guard let handle else { throw CommoError(description: "commo is shut down") }
        return handle
    }

    private static func initLibraries() throws {
        try check { err, len in mactak_commo_init_libraries(err, len) }
    }

    /// Run a shim call that reports failure as nonzero plus a message.
    private static func check(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var err = [CChar](repeating: 0, count: 512)
        let count = err.count
        let rc = err.withUnsafeMutableBufferPointer { body($0.baseAddress!, count) }
        if rc != 0 { throw CommoError(description: String(cString: err)) }
    }

    /// Run a shim call that reports failure as NULL plus a message.
    private static func call(_ body: (UnsafeMutablePointer<CChar>, Int) -> OpaquePointer?) throws -> OpaquePointer {
        var err = [CChar](repeating: 0, count: 512)
        let count = err.count
        let result = err.withUnsafeMutableBufferPointer { body($0.baseAddress!, count) }
        guard let result else { throw CommoError(description: String(cString: err)) }
        return result
    }
}

/// Where commo's callbacks land: commo's threads, so only thread-safe parts
/// (the streams' continuations, which may be called from any thread).
private final class EventSink: @unchecked Sendable {
    private let events: AsyncStream<CommoEvent>.Continuation
    private let interfaceUps: AsyncStream<Void>.Continuation
    private let logLevel: CommoLogLevel

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
        return cb
    }()
}
