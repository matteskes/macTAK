// JavaNumbers.swift — Java's number rules, where 5.5's coordinate code
// depends on them (G3.6a).
//
// ATAK formats coordinates with java.text.DecimalFormat (Locale.US), rounds
// with Math.round, parses with Double.parseDouble and Integer.parseInt, and
// casts with (int). Each differs from Swift's nearest equivalent at an edge
// the coordinate strings reach: DecimalFormat rounds the double's exact
// binary value (1.005 is 1.00499…), keeps the sign of a negative that
// rounds to zero ("-0.00"), and Math.round takes halves up, not away from
// zero. The golden fixtures (dev/g3/test/coord-golden) hold these to the
// JVM's answers.

import Foundation

enum JavaNumber {
    /// DecimalFormat with RoundingMode.HALF_UP, `minInt` integer digits and
    /// exactly `fraction` fraction digits ("00.0000" is minInt 2, fraction
    /// 4); `grouping` puts a comma every three integer digits ("#,##0").
    static func format(_ x: Double, minInt: Int = 1, fraction: Int = 0, grouping: Bool = false) -> String {
        let sign = isNegative(x) ? "-" : ""
        if x.isNaN { return "NaN" }
        if x.isInfinite { return sign + "∞" }
        // The exact decimal value: |x| ≥ 2^-10 has at most 62 fraction
        // digits, so 80 leaves nothing for printf to round; anything
        // smaller rounds to zero at the precisions used here.
        let exact = String(format: "%.80f", abs(x))
        let point = exact.firstIndex(of: ".")!
        var digits = Array(exact[..<point]) + Array(exact[exact.index(after: point)...].prefix(fraction))
        let dropped = exact[exact.index(after: point)...].dropFirst(fraction).first ?? "0"
        if dropped >= "5" {   // HALF_UP: an exact half goes up
            var i = digits.count - 1
            while i >= 0 {
                if digits[i] == "9" { digits[i] = "0"; i -= 1 } else { digits[i] = Character(String(digits[i].wholeNumberValue! + 1)); break }
            }
            if i < 0 { digits.insert("1", at: 0) }
        }
        var integer = String(digits[..<(digits.count - fraction)])
        while integer.count > 1 && integer.first == "0" { integer.removeFirst() }
        if integer.count < minInt { integer = String(repeating: "0", count: minInt - integer.count) + integer }
        if grouping { integer = grouped(integer) }
        let frac = String(digits[(digits.count - fraction)...])
        return sign + integer + (fraction > 0 ? "." + frac : "")
    }

    /// An integral long, as DecimalFormat writes it.
    static func format(_ n: Int64, grouping: Bool = false) -> String {
        let digits = String(n.magnitude)
        return (n < 0 ? "-" : "") + (grouping ? grouped(digits) : digits)
    }

    private static func grouped(_ digits: String) -> String {
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return out
    }

    /// Math.round(double): the nearest long, halves up (-2.5 is -2); NaN is 0.
    static func round(_ x: Double) -> Int64 {
        if x.isNaN { return 0 }
        let floor = x.rounded(.down)
        let r = x - floor >= 0.5 ? floor + 1 : floor
        if r >= 9.223372036854775807e18 { return .max }
        if r <= -9.223372036854775808e18 { return .min }
        return Int64(r)
    }

    /// The (int) cast: toward zero, NaN is 0, clamped to int's range.
    static func int(_ x: Double) -> Int {
        if x.isNaN { return 0 }
        if x >= 2147483647 { return Int(Int32.max) }
        if x <= -2147483648 { return Int(Int32.min) }
        return Int(x)
    }

    /// Double.compare's view of the sign: -0.0 is negative.
    static func isNegative(_ d: Double) -> Bool { d.sign == .minus && !d.isNaN }

    /// Double.parseDouble: trims what String.trim does (code points ≤ U+0020),
    /// takes "NaN", "Infinity", decimal and hex forms and a trailing
    /// f/F/d/D; nil where Java throws NumberFormatException.
    static func parseDouble(_ s: String) -> Double? {
        var t = Substring(trimmed(s))
        var negative = false
        if let first = t.first, first == "+" || first == "-" { negative = first == "-"; t = t.dropFirst() }
        if t == "NaN" { return .nan }
        if t == "Infinity" { return negative ? -.infinity : .infinity }
        if let last = t.last, "fFdD".contains(last) { t = t.dropLast() }
        let lower = t.lowercased()
        guard !t.isEmpty, t.first != "+", t.first != "-", !lower.hasPrefix("inf"), !lower.hasPrefix("nan"),
              !lower.hasPrefix("0x") || lower.contains("p"),
              t.allSatisfy({ $0.isASCII }), let v = Double(t) else { return nil }
        return negative ? -v : v
    }

    /// Integer.parseInt: an optional sign and ASCII digits, in int's range.
    static func parseInt(_ s: String) -> Int? {
        guard s.allSatisfy({ $0.isASCII }), let v = Int32(s) else { return nil }
        return Int(v)
    }

    /// String.trim().
    static func trimmed(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        guard let start = scalars.firstIndex(where: { $0.value > 0x20 }),
              let end = scalars.lastIndex(where: { $0.value > 0x20 }) else { return "" }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[start...end])
        return String(out)
    }

    /// Character.isDigit for one UTF-16 unit.
    static func isDigit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.numericType == .decimal
    }
}

/// A Java string's UTF-16 view, for code that indexes it as Java does
/// (charAt, substring, indexOf), throwing where Java throws.
struct JavaString {
    let units: [UInt16]

    init(_ s: String) { units = Array(s.utf16) }

    var length: Int { units.count }

    func charAt(_ i: Int) throws -> UInt16 {
        guard i >= 0 && i < units.count else { throw JavaException.indexOutOfBounds }
        return units[i]
    }

    func substring(_ from: Int, _ to: Int? = nil) throws -> String {
        let end = to ?? units.count
        guard from >= 0, end <= units.count, from <= end else { throw JavaException.indexOutOfBounds }
        return String(decoding: units[from..<end], as: UTF16.self)
    }
}

/// What Java would throw that isn't an IllegalArgumentException.
enum JavaException: Error {
    case indexOutOfBounds
    case numberFormat
}

extension String {
    /// String.indexOf(char) for a UTF-16 unit: -1 when absent.
    func javaIndexOf(_ unit: UInt16) -> Int { Array(utf16).firstIndex(of: unit) ?? -1 }

    /// String.replace(CharSequence, CharSequence): every literal occurrence.
    func javaReplace(_ target: String, _ replacement: String) -> String {
        replacingOccurrences(of: target, with: replacement, options: .literal)
    }
}
