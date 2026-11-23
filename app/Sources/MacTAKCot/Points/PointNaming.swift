// PointNaming.swift — what a dropped point is called (G3.9b), as ATAK 5.5
// names it (PlacePointTool at the pin):
//
// - genCallsign: a prefix by type, then the day of the month and the time
//   to the second, in this Mac's time zone ("U.23.143205"). The prefixes:
//   a-h R (civ_tgtPrefix; TGT is the military flavour's), a-f F, a-u U,
//   a-n N, b-m-p-s-m S, b-r-f-h-c MED; any other type, or the
//   legacyPointDropNaming preference, uses the device callsign.
// - placePoint's de-duplication: when points of the same type in the
//   point's group already have the name, or the name and ".something",
//   ".count" is added.
// - getCount: the lowest n from 1 not used by a title "<prefix> n" (Spot
//   Map's "W 1", "W 2", …), with 5.5's way of splitting and reading titles.

import Foundation

public enum PointNaming {
    /// 5.5's preference key that names points by the device callsign.
    public static let legacyPointDropNamingKey = "legacyPointDropNaming"

    /// genCallsign's prefix for a type; nil uses the device callsign.
    public static func prefix(forType type: String) -> String? {
        let t = type.lowercased()
        if t.hasPrefix("a-h") { return "R" }
        if t.hasPrefix("a-f") { return "F" }
        if t.hasPrefix("a-u") { return "U" }
        if t.hasPrefix("a-n") { return "N" }
        if t.hasPrefix("b-m-p-s-m") { return "S" }
        if t.hasPrefix("b-r-f-h-c") { return "MED" }
        return nil
    }

    /// genCallsign: prefix "." day "." HHmmss, at `date` in `timeZone`.
    public static func callsign(type: String, deviceCallsign: String, legacy: Bool = false, at date: Date,
                                timeZone: TimeZone = .current) -> String {
        let prefix = legacy ? deviceCallsign : (prefix(forType: type) ?? deviceCallsign)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.day, .hour, .minute, .second], from: date)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        return "\(prefix).\(c.day ?? 0).\(two(c.hour))\(two(c.minute))\(two(c.second))"
    }

    /// placePoint's de-duplication: `callsign`, or `callsign.count` when
    /// `existing` (the callsigns of the same-type points in its group) has
    /// that many equal to it or starting with it and a dot.
    public static func deduplicated(_ callsign: String, among existing: [String]) -> String {
        let count = existing.filter { $0 == callsign || $0.hasPrefix(callsign + ".") }.count
        return count > 0 ? "\(callsign).\(count)" : callsign
    }

    /// getCount: the lowest n from 1 that no title "<prefix> n" uses. A
    /// title with a word count other than the prefix's plus one counts only
    /// when the prefix is empty; a last word that isn't a number reads as 0.
    public static func count(prefix: String, titles: [String]) -> Int {
        let words = javaSplit(prefix)
        var used: [Int] = []
        for title in titles {
            let n = javaSplit(title)
            let match: Bool
            if words.count == n.count - 1 {
                match = zip(words, n).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
            } else {
                match = prefix.isEmpty
            }
            // a blank title splits to nothing: 5.5 would throw reading its last word
            used.append(match ? n.last.flatMap { Int32($0) }.map(Int.init) ?? 0 : 0)
        }
        var num = 1
        for u in used.sorted() where u == num { num += 1 }
        return num
    }

    /// Java's String.split(" "): trailing empty strings dropped, and "" is [""].
    static func javaSplit(_ s: String) -> [String] {
        if s.isEmpty { return [""] }
        var parts = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        if parts == [""] { return [] }   // " " splits to nothing
        return parts
    }
}
