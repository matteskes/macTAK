// CotEvent.swift — a CoT event and its point (G3.4).
//
// Ported from the kernel's com.atakmap.coremap.cot.event.CotEvent and
// CotPoint at the pin. The XML they write is what Android peers write
// (dev/g3/test/cot-golden checks it against the kernel itself).

import Foundation

public struct CotPoint: Sendable, Equatable {
    /// The kernel's "unknown" for hae, ce and le.
    public static let unknown = 9_999_999.0
    /// Where an event with no point sits (the kernel's CotPoint.ZERO).
    public static let zero = CotPoint(lat: 0, lon: 0)

    public var lat: Double
    public var lon: Double
    public var hae: Double
    public var ce: Double
    public var le: Double

    public init(lat: Double, lon: Double, hae: Double = unknown, ce: Double = unknown, le: Double = unknown) {
        self.lat = lat; self.lon = lon
        self.hae = Self.isInvalid(hae) ? Self.unknown : hae
        self.ce = Self.isInvalid(ce) ? Self.unknown : ce
        self.le = Self.isInvalid(le) ? Self.unknown : le
    }

    /// The kernel's CotPoint.isInvalid: a hae, ce or le CoT marks unknown
    /// (9999999) or that isn't a number. CoT keeps any other value as it
    /// came; the map's side checks the altitude's range (`validAltitude`).
    public static func isInvalid(_ value: Double) -> Bool { value == unknown || value.isNaN }

    /// The altitude as 5.5's map side takes it (CotPoint.toGeoPoint, then
    /// GeoPoint.isAltitudeValid): nil when CoT marks it unknown or it is
    /// outside −14000…76000 m.
    public var validAltitude: Double? { Altitude.isValid(hae) ? hae : nil }

    public var isValid: Bool { (-90...90).contains(lat) && (-180...180).contains(lon) }

    /// The kernel rounds as it writes: 7 decimals for lat and lon, 4 for hae
    /// (it says 4; its factor is 1000, so 3), 1 for ce and le.
    func write(to out: inout String) {
        func rounded(_ v: Double, _ factor: Double) -> String { Cot.number((v * factor).rounded() / factor) }
        out += "<point lat='\(rounded(lat, 1e7))' lon='\(rounded(lon, 1e7))' hae='\(rounded(hae, 1e3))'"
            + " ce='\(rounded(ce, 10))' le='\(rounded(le, 10))'/>"
    }
}

public struct CotEvent: Sendable, Equatable {
    public var version = "2.0"
    public var uid: String
    public var type: String
    public var time: Date
    public var start: Date
    public var stale: Date
    public var how: String
    public var opex: String?
    public var qos: String?
    public var access: String?
    public var caveat: String?
    public var releasableTo: String?
    public var point: CotPoint
    public var detail: CotDetail?

    public init(uid: String, type: String, time: Date, start: Date? = nil, stale: Date,
                how: String, point: CotPoint = .zero, detail: CotDetail? = nil) {
        self.uid = uid; self.type = type
        self.time = time; self.start = start ?? time; self.stale = stale
        self.how = how; self.point = point; self.detail = detail
    }

    /// The kernel's CotEvent.isValid.
    public var isValid: Bool {
        !uid.trimmingCharacters(in: .whitespaces).isEmpty
            && !type.trimmingCharacters(in: .whitespaces).isEmpty
            && !how.trimmingCharacters(in: .whitespaces).isEmpty
            && point.isValid
    }

    /// 5.5's MarkerImporter autoStaleDuration: how long after it arrives a
    /// marker or contact goes stale. 3 × (stale − start) / 2, in whole
    /// milliseconds as Java's long division leaves it, and 0 when stale is
    /// before start ("some systems are generating a negative number").
    /// The app's MarkerImporter sets none on a special type; the stores
    /// decide that.
    public var autoStaleDuration: TimeInterval {
        let millis = (3 * (Cot.millis(stale) - Cot.millis(start))) / 2
        return TimeInterval(max(0, millis)) / 1000
    }

    /// The first element under <detail> with this name.
    public func detail(_ name: String) -> CotDetail? {
        detail?.child(name)
    }

    /// The event as XML, in the kernel's layout. Every value is escaped,
    /// type and how included (the kernel escapes only the uid there).
    public func xml() -> String {
        var out = "<?xml version='1.0' encoding='UTF-8' standalone='yes'?><event"
        if !version.isEmpty { out += " version='\(Cot.escape(version))'" }
        out += " uid='\(Cot.escape(uid))' type='\(Cot.escape(type))'"
        out += " time='\(Cot.time(time))' start='\(Cot.time(start))' stale='\(Cot.time(stale))'"
        out += " how='\(Cot.escape(how))'"
        if let opex { out += " opex='\(Cot.escape(opex))'" }
        if let qos { out += " qos='\(Cot.escape(qos))'" }
        let access = self.access.flatMap { $0.isEmpty ? nil : $0 } ?? Cot.undefinedAccess
        out += " access='\(Cot.escape(access))'"
        if let caveat { out += " caveat='\(Cot.escape(caveat))'" }
        if let releasableTo { out += " releasableTo='\(Cot.escape(releasableTo))'" }
        out += ">"
        point.write(to: &out)
        detail?.write(to: &out)
        out += "</event>"
        return out
    }
}
