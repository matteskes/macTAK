// MGRSPoint.swift — MGRS, ported from the kernel's MGRSPoint at the pin
// (G3.6a): the UTM point, then the 100 km square letters and the metres
// into it. UTM-based only, as in 5.5 (no UPS).

import Foundation

public struct MGRSPoint: Equatable, Sendable {
    public private(set) var utm: UTMPoint
    private var xGrid = 0
    private var yGrid = 0
    /// Metres into the 100 km square.
    private var easting = 0.0
    private var northing = 0.0

    private static let latGridChars = Array("ABCDEFGHJKLMNPQRSTUV".utf16)
    private static let lngGridChars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ".utf16)
    /// 1 cm: a square's metres floor with this added.
    private static let epsilon = 0.01

    /// fromLatLng.
    public init(lat: Double, lng: Double) {
        self.init(utm: UTMPoint(lat: lat, lng: lng))
    }

    init(utm: UTMPoint) {
        self.utm = utm
        calcMGRSFromUTM()
    }

    public func toLatLng() -> (lat: Double, lng: Double) { utm.toLatLng() }

    private mutating func calcMGRSFromUTM() {
        let lngZone = utm.lngZone
        let evenOffset = lngZone % 2 == 0 ? 5 : 0   // F for even zones, A for odd
        let utmNorthing = utm.northing
        if utm.latZone < 10 {
            let equatorOffset = utmNorthing - 10000000
            let yGridOffset = (equatorOffset / 100000).rounded(.down)
            yGrid = (evenOffset + JavaNumber.int(yGridOffset)) % 20
            if yGrid < 0 { yGrid += 20 }
            northing = equatorOffset - yGridOffset * 100000
        } else {
            yGrid = (JavaNumber.int(utmNorthing / 100000) + evenOffset) % 20
            northing = utmNorthing.truncatingRemainder(dividingBy: 100000)
        }
        var lngGridMeridian = 4   // E
        switch (lngZone - 1) % 3 {
        case 1: lngGridMeridian = 12   // N
        case 2: lngGridMeridian = 20   // W
        default: break
        }
        let meridianOffset = utm.easting - 500000
        let xGridOffset = (meridianOffset / 100000).rounded(.down)
        xGrid = lngGridMeridian + JavaNumber.int(xGridOffset)
        easting = meridianOffset - xGridOffset * 100000
        // checkValues: 5.5 logs and uses A for a letter out of range
        if yGrid < 0 || yGrid > Self.latGridChars.count - 1 { yGrid = 0 }
        if xGrid < 0 || xGrid > Self.lngGridChars.count - 1 { xGrid = 0 }
    }

    /// "33T", or "---" for a band letter 5.5 couldn't read.
    public var zoneDescriptor: String { utm.zoneDescriptor ?? "---" }

    /// The 100 km square, "VM".
    public var gridDescriptor: String {
        String(decoding: [Self.lngGridChars[xGrid], Self.latGridChars[yGrid]], as: UTF16.self)
    }

    public var eastingDescriptor: String { Self.descriptor(easting) }
    public var northingDescriptor: String { Self.descriptor(northing) }

    private static func descriptor(_ metres: Double) -> String {
        let floored = (metres + epsilon).rounded(.down)
        return floored >= 100000 ? "99999" : JavaNumber.format(floored, minInt: 5)
    }

    /// getFormattedString: "33T  VM  12345  67890", as 5.5's self readout
    /// shows MGRS.
    public var formattedString: String {
        zoneDescriptor + "  " + gridDescriptor + "  " + eastingDescriptor + "  " + northingDescriptor
    }

    /// decodeString: "4QFJ12345678", "04QFJ1234567890", spaces and LRMs
    /// optional. Throws where 5.5 throws (a zone that isn't a number, too
    /// few characters); a letter it doesn't know comes out as 5.5's does.
    static func decode(_ text: String) throws -> MGRSPoint {
        var s = text.javaReplace(" ", "").javaReplace("\u{200E}", "")
        if !JavaNumber.isDigit(try JavaString(s).charAt(1)) { s = "0" + s }
        let js = JavaString(s)
        guard let lngZone = JavaNumber.parseInt(try js.substring(0, 2)) else { throw JavaException.numberFormat }
        let latZone = UTMPoint.latZoneChars.firstIndex(of: try js.charAt(2)) ?? -1

        // the zone's centre
        let lat = UTMPoint.zoneLatitude(latZone) + UTMPoint.zoneLatitudeSpan(latZone) / 2
        let lng = UTMPoint.zoneLongitude(lngZone) + UTMPoint.zoneLongitudeSpan / 2
        var r = MGRSPoint(utm: UTMPoint(lat: lat, lng: lng))

        var eastingText = "0", northingText = "0"
        var e = 1.0
        if js.length > 5 {
            let compSize = (js.length - 5) / 2
            if compSize > 0 {
                eastingText = try js.substring(5, 5 + compSize)
                northingText = try js.substring(5 + compSize, 5 + compSize + compSize)
            }
            switch compSize {
            case 1: e = 10000
            case 2: e = 1000
            case 3: e = 100
            case 4: e = 10
            default: break
            }
        }
        guard let eastingValue = JavaNumber.parseDouble(eastingText),
              let northingValue = JavaNumber.parseDouble(northingText) else { throw JavaException.numberFormat }

        // the offset from the zone's centre to the square and the metres in it
        let eastingOffset = Double(xGridOffset(r.xGrid, try js.charAt(3))) * 100000 - r.easting + eastingValue * e
        let northingOffset = Double(yGridOffset(r.yGrid, try js.charAt(4))) * 100000 - r.northing + northingValue * e
        r.utm.offset(easting: eastingOffset, northing: northingOffset)
        r.calcMGRSFromUTM()
        return r
    }

    private static func yGridOffset(_ zeroIndex: Int, _ yGridChar: UInt16) -> Int {
        guard let index = latGridChars.firstIndex(of: yGridChar) else { return 0 }
        var offset = index - zeroIndex
        if offset < -9 { offset += 20 } else if offset > 10 { offset -= 20 }
        return offset
    }

    private static func xGridOffset(_ zeroIndex: Int, _ xGridChar: UInt16) -> Int {
        guard let index = lngGridChars.firstIndex(of: xGridChar) else { return 0 }
        var offset = index - zeroIndex
        if offset < -11 { offset += 24 } else if offset > 22 { offset -= 24 }
        return offset
    }
}
