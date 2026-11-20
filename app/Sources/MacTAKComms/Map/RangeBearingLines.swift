// RangeBearingLines.swift — the range and bearing lines on the map and the
// tool that makes them (G3.8c), as ATAK 5.5 has them
// (RangeAndBearingTool, RangeAndBearingMapItem):
//
// - the tool takes two clicks: the start, then the end. A click on a marker
//   ties that end to it (the line follows it as it moves); a click on the
//   map fixes the end there, and the first such click shows a red start
//   point until the line is made. The same marker twice is ignored. The
//   line is made on the second click and the tool ends.
// - a line is titled "R&B n", the lowest n no other line has.
// - when a marker an end is tied to goes away, the line stays and that end
//   stays where the marker last was (removePoint).
//
// The map side (drawing, the label from the Units preferences) is the app's
// MapMarkerSync; this file holds what the lines are.

import Foundation
import MacTAKCot

/// One end of a range and bearing line.
public enum RangeBearingEnd: Equatable, Sendable {
    /// Tied to the marker with this uid (a contact, a CoT marker, the self).
    case item(String)
    /// A fixed place.
    case point(CotPoint)
}

public struct RangeBearingLine: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var start: RangeBearingEnd
    public var end: RangeBearingEnd
}

/// What a click on the map hit, for the tool.
public enum MapPick: Equatable, Sendable {
    case item(String)
    case ground(CotPoint)
}

@MainActor
public final class RangeBearingLines: ObservableObject {
    public enum ToolState: Equatable, Sendable {
        case off
        /// Waiting for the start (5.5's rb_prompt).
        case pickingStart
        /// Waiting for the end (rb_prompt3 after a marker, rb_measure_prompt after a place).
        case pickingEnd(RangeBearingEnd)
    }

    @Published public private(set) var lines: [RangeBearingLine] = []
    @Published public private(set) var tool: ToolState = .off
    /// Each line's label as the map last drew it, by line id (for the list).
    @Published public private(set) var labels: [String: String] = [:]
    private let newID: () -> String

    public init(newID: @escaping () -> String = { UUID().uuidString }) {
        self.newID = newID
    }

    // ---- the tool -----------------------------------------------------------

    public func beginTool() { tool = .pickingStart }

    /// Cancel: nothing is made.
    public func endTool() { tool = .off }

    /// The tool's prompt, 5.5's wording; nil while it is off.
    public var prompt: String? {
        switch tool {
        case .off: nil
        case .pickingStart: "Click the point to measure from."
        case .pickingEnd(.item): "Click the point to measure range and bearing to."
        case .pickingEnd(.point): "Click the point to measure to."
        }
    }

    /// The red start point shown while the end is picked after a click on the map.
    public var startPoint: CotPoint? {
        if case .pickingEnd(.point(let p)) = tool { return p }
        return nil
    }

    /// A click while the tool is on; returns the line it made, if any.
    @discardableResult
    public func click(_ pick: MapPick) -> RangeBearingLine? {
        let end: RangeBearingEnd = switch pick {
        case .item(let uid): .item(uid)
        case .ground(let p): .point(p)
        }
        switch tool {
        case .off:
            return nil
        case .pickingStart:
            tool = .pickingEnd(end)
            return nil
        case .pickingEnd(let start):
            if case .item = end, end == start { return nil }   // the same marker twice
            let line = add(start: start, end: end)
            tool = .off
            return line
        }
    }

    // ---- the lines ----------------------------------------------------------

    @discardableResult
    public func add(start: RangeBearingEnd, end: RangeBearingEnd) -> RangeBearingLine {
        let line = RangeBearingLine(id: newID(), title: nextTitle(), start: start, end: end)
        lines.append(line)
        return line
    }

    public func remove(id: String) {
        lines.removeAll { $0.id == id }
        labels[id] = nil
    }

    public func removeAll() {
        lines.removeAll()
        labels.removeAll()
    }

    /// The labels the map drew; published only when they change.
    public func setLabels(_ new: [String: String]) {
        if new != labels { labels = new }
    }

    /// "R&B n", the lowest n not taken (RangeAndBearingImporter.getInstanceNum).
    func nextTitle() -> String {
        let taken = Set(lines.map(\.title))
        var n = 1
        while taken.contains("R&B \(n)") { n += 1 }
        return "R&B \(n)"
    }

    /// Where the lines' ends are now: each tied end at its marker's place
    /// in `markers` (uid → place). An end whose marker has gone becomes a
    /// fixed place where the marker was last seen (5.5's removePoint); a
    /// line whose marker hasn't been seen yet is left out until it is.
    public func ends(markers: [String: CotPoint]) -> [(line: RangeBearingLine, start: CotPoint, end: CotPoint)] {
        let tied = tiedUIDs
        for (uid, p) in markers where tied.contains(uid) { lastSeen[uid] = p }
        var resolved: [(RangeBearingLine, CotPoint, CotPoint)] = []
        for i in lines.indices {
            if let pinned = pin(lines[i].start, markers) { lines[i].start = pinned }
            if let pinned = pin(lines[i].end, markers) { lines[i].end = pinned }
            guard let s = place(lines[i].start, markers), let e = place(lines[i].end, markers) else { continue }
            resolved.append((lines[i], s, e))
        }
        let stillTied = tiedUIDs
        lastSeen = lastSeen.filter { stillTied.contains($0.key) }
        return resolved
    }

    /// Where each tied marker was last seen.
    private var lastSeen: [String: CotPoint] = [:]

    private var tiedUIDs: Set<String> {
        var uids = Set<String>()
        for line in lines {
            if case .item(let uid) = line.start { uids.insert(uid) }
            if case .item(let uid) = line.end { uids.insert(uid) }
        }
        if case .pickingEnd(.item(let uid)) = tool { uids.insert(uid) }
        return uids
    }

    /// The fixed end a tied end becomes once its marker has gone, else nil.
    private func pin(_ end: RangeBearingEnd, _ markers: [String: CotPoint]) -> RangeBearingEnd? {
        guard case .item(let uid) = end, markers[uid] == nil, let last = lastSeen[uid] else { return nil }
        return .point(last)
    }

    private func place(_ end: RangeBearingEnd, _ markers: [String: CotPoint]) -> CotPoint? {
        switch end {
        case .point(let p): p
        case .item(let uid): markers[uid]
        }
    }
}
