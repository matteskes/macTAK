// Presence.swift — the self-SA event a TAK client beacons (G3.1).
//
// Ported from dev/g1/headless/src/mactak/headless/CotXml.java (presence and
// xmlEscape), which G1 proved against FreeTAKServer and OpenTAKServer. The
// CoT model proper (parsing, contacts, markers) is G3.2's.

import Foundation

public struct Presence: Sendable {
    public struct Position: Sendable {
        public var lat: Double
        public var lon: Double
        public var hae: Double
        public init(lat: Double, lon: Double, hae: Double = 0) {
            self.lat = lat; self.lon = lon; self.hae = hae
        }
    }

    public var uid: String
    public var callsign: String
    /// nil until the client knows where it is: sent as 0,0 with an unknown
    /// (9999999 m) error, as ATAK does.
    public var position: Position?
    public var team = "Cyan"
    public var role = "Team Member"
    /// How long receivers keep showing this contact without a newer beacon.
    public var stale: TimeInterval = 30

    public init(uid: String, callsign: String, position: Position? = nil) {
        self.uid = uid; self.callsign = callsign; self.position = position
    }

    /// The event as XML. Self-SA (a-f-G-U-C with contact, __group, takv and
    /// uid) is what registers a client on a TAK server: OpenTAKServer starts
    /// a client's fan-out only after a parseable one with uid, callsign and
    /// group arrives.
    public func xml(at now: Date = Date()) -> String {
        let uid = Cot.escape(uid), callsign = Cot.escape(callsign)
        let t = Cot.time(now), staleTime = Cot.time(now.addingTimeInterval(stale))
        let point: String
        if let p = position {
            point = "<point lat='\(Cot.number(p.lat))' lon='\(Cot.number(p.lon))' ce='10.0' le='10.0' hae='\(Cot.number(p.hae))'/>"
        } else {
            point = "<point lat='0.0' lon='0.0' ce='9999999' le='9999999' hae='0.0'/>"
        }
        return "<event version='2.0' uid='\(uid)' type='a-f-G-U-C'\(Cot.access)"
            + " time='\(t)' start='\(t)' stale='\(staleTime)' how='m-g'>"
            + point
            + "<detail>"
            + "<takv os='macOS' device='Mac' platform='macTAK' version='\(Cot.escape(Cot.clientVersion))'/>"
            + "<contact endpoint='*:-1:stcp' callsign='\(callsign)'/>"
            + "<uid Droid='\(callsign)'/>"
            + "<__group name='\(Cot.escape(team))' role='\(Cot.escape(role))'/>"
            + "<status battery='100'/>"
            + "<track course='0.0' speed='0.0'/>"
            + "</detail></event>"
    }
}

/// What every outgoing event shares.
public enum Cot {
    /// The takv version: the app bundle's, or "dev" outside one (tests, tools).
    public static let clientVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    /// Every outgoing event's access. MIL-STD-6090 requires it, and 5.5's
    /// takproto asks new clients to send it, "Undefined" when there is no
    /// real value.
    static let access = " access='Undefined'"

    private static let timeFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static let timeLock = NSLock()

    /// CoT time: UTC, milliseconds, "Z".
    public static func time(_ date: Date) -> String {
        timeLock.lock(); defer { timeLock.unlock() }
        return timeFormat.string(from: date)
    }

    /// A coordinate as a plain decimal (no exponent), as CoT parsers expect.
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0.0" }
        let s = "\(value)"
        if !s.contains("e") { return s }
        return String(format: "%.9f", value)
    }

    /// value escaped for an XML attribute or text node. The five markup
    /// characters become entities; tab, LF and CR become character
    /// references (a parser would turn them into spaces in an attribute);
    /// characters XML 1.0 cannot carry at all become U+FFFD, since one of
    /// them makes the whole event unparseable.
    public static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "'": out += "&apos;"
            case "\"": out += "&quot;"
            case "\t": out += "&#9;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF {
                    out += "\u{FFFD}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
