// Cot.swift — what every CoT event shares: times, numbers and escaping (G3.4).
//
// Moved from MacTAKComms/Presence.swift (G3.1). The escaping is a superset
// of the kernel's CotEvent.escapeXmlText: it also covers tab, CR and the
// characters XML 1.0 cannot carry at all.

import Foundation

public enum Cot {
    /// The takv version: the app bundle's, or "dev" outside one (tests, tools).
    public static let clientVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    /// MIL-STD-6090 requires `access`; the kernel writes "Undefined" when an
    /// event has none, and 5.5's takproto asks new clients to do the same.
    public static let undefinedAccess = "Undefined"

    private static let timeFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static let wholeSecondTimeFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static let timeLock = NSLock()

    /// CoT time: UTC, milliseconds, "Z" (the kernel's CoordinatedTime).
    public static func time(_ date: Date) -> String {
        timeLock.lock(); defer { timeLock.unlock() }
        return timeFormat.string(from: date)
    }

    /// A CoT time as peers send it: with or without fractional seconds.
    public static func parseTime(_ text: String) -> Date? {
        timeLock.lock(); defer { timeLock.unlock() }
        return timeFormat.date(from: text) ?? wholeSecondTimeFormat.date(from: text)
    }

    /// A number as a plain decimal (no exponent), as CoT parsers expect.
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
