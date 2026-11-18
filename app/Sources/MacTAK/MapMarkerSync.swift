// MapMarkerSync.swift — the map's markers follow the contacts, the CoT
// markers heard (G3.7c) and the self position (G3.7b).
//
// Once a second it works out every marker the map should show, as ATAK 5.5
// draws them (MarkerIcons), and sends the engine only what changed:
//   - each contact at its point, its icon, its callsign as the label; grey
//     once stale, gone once the contact store drops it
//   - each CoT marker likewise, labelled with its callsign (or uid), in
//     5.5's icon for its type and details
//   - the self marker: 5.5's self icon (SelfIcon on the engine side), turned
//     by the track's course, no label.
// The tick also catches contacts and markers going stale, which publishes
// nothing.
// While the map isn't running nothing is sent; when it starts, everything is
// (the engine's marker layer starts empty).

import Foundation
import MacTAKComms
import MacTAKCore
import MacTAKCot

@MainActor
final class MapMarkerSync {
    /// One marker as the engine was last told it.
    struct Marker: Equatable {
        var lat, lon: Double
        var hae: Double?
        var icon: MarkerIcon
        var rotation: Double?
        var label: String?
    }

    static let tick: TimeInterval = 1

    private let host: EngineHost
    private let contacts: ContactStore
    private let cotMarkers: CotMarkerStore
    private let me: SelfReporter
    private var timer: Timer?
    /// What the engine has, by uid; nil until the map takes markers.
    private var sent: [String: Marker]?
    private var symbols: CotSymbols?
    private var symbolIcons: [String: String?] = [:]
    private var selfIcon: String?

    init(host: EngineHost, contacts: ContactStore, cotMarkers: CotMarkerStore, me: SelfReporter) {
        self.host = host
        self.contacts = contacts
        self.cotMarkers = cotMarkers
        self.me = me
    }

    func start() {
        let t = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sync(now: Date = Date()) {
        guard let engine = host.markerEngine else {
            sent = nil   // a map that starts again starts empty
            return
        }
        var have = sent ?? [:]
        let want = markers(engine, now: now)
        for (uid, m) in want where have[uid] != m {
            engine.putMarker(uid: uid, lat: m.lat, lon: m.lon, hae: m.hae, iconURI: m.icon.uri, color: m.icon.color,
                             width: m.icon.width, height: m.icon.height, rotation: m.rotation, label: m.label)
            have[uid] = m
        }
        for uid in have.keys where want[uid] == nil {
            engine.removeMarker(uid: uid)
            have[uid] = nil
        }
        sent = have
    }

    private func markers(_ engine: EngineBridge, now: Date) -> [String: Marker] {
        var want: [String: Marker] = [:]
        for m in cotMarkers.markers {
            let icon = MarkerIcons.icon(m.traits, stale: m.isStale(at: now)) { symbolIcon($0, engine) }
            want[m.uid] = Marker(lat: m.point.lat, lon: m.point.lon, hae: Self.hae(m.point), icon: icon,
                                 rotation: nil, label: m.label)
        }
        for c in contacts.contacts {
            let icon = MarkerIcons.contact(c, stale: c.isStale(at: now)) { symbolIcon($0, engine) }
            want[c.uid] = Marker(lat: c.point.lat, lon: c.point.lon, hae: Self.hae(c.point), icon: icon,
                                 rotation: nil, label: c.callsign)
        }
        if let location = me.location {
            let uri = selfIcon ?? engine.selfIconURI(fill: SelfMarker.fill, stroke: SelfMarker.stroke)
            selfIcon = uri
            let course = me.track.course
            want[me.details.uid] = Marker(
                lat: location.point.lat, lon: location.point.lon, hae: Self.hae(location.point),
                icon: MarkerIcon(uri: uri, width: SelfMarker.width, height: SelfMarker.height),
                rotation: course.isFinite ? course : nil, label: nil)
        }
        return want
    }

    /// A CoT type's 2525C symbol as a base64:// icon, or nil when none draws.
    private func symbolIcon(_ type: String, _ engine: EngineBridge) -> String? {
        if let known = symbolIcons[type] { return known }
        let mapper = symbols ?? CotSymbols { engine.canRenderSymbol($0) }
        symbols = mapper
        let code = mapper.mil2525C(fromCotType: type).uppercased()
        let uri = code.isEmpty ? nil : engine.symbolPNG(code).map(Self.base64URI)
        symbolIcons[type] = uri
        return uri
    }

    /// The engine's base64:// loader decodes URL-safe Base64.
    static func base64URI(_ png: [UInt8]) -> String {
        let s = Data(png).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "base64://" + s
    }

    private static func hae(_ p: CotPoint) -> Double? {
        p.hae == CotPoint.unknown ? nil : p.hae
    }
}

/// 5.5's self marker (LocationMapComponent): 32 x 43, its default colours.
enum SelfMarker {
    static let width = 32, height = 43
    static let fill: UInt32 = 0xFF44_B2DD
    static let stroke: UInt32 = 0xFFFF_FFFF
}
