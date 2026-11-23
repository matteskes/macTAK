// Golden.swift — the golden fixtures in dev/g3/test/cot-golden, and the
// canonical form both legs compare in (G3.4).
//
// The kernel's leg (dev/g3/test/CotOracle.java, make test-cot-golden) reads
// the same files and compares in the same form, so the two agree only if
// the Swift port and the kernel write the same events. The form:
//   - elements in document order, attributes sorted by name (the kernel
//     keeps them in a HashMap, so their order means nothing)
//   - <point>'s numbers to 7 decimals, so "9999999" and "9999999.0" match
//   - text trimmed, and empty text the same as none
//   - the XML declaration, quoting and escaping don't count.

import Foundation
@testable import MacTAKCot

enum Golden {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("dev/g3/test/cot-golden")

    /// Set to rewrite the expected files from the Swift port; the kernel's
    /// leg must then pass on them unchanged.
    static var writing: Bool { ProcessInfo.processInfo.environment["MACTAK_COT_GOLDEN_WRITE"] == "1" }

    static func inputs(_ kind: String, _ ext: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(kind), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func expectedURL(_ kind: String, _ input: URL) -> URL {
        root.appendingPathComponent("expected/\(kind)-\(input.deletingPathExtension().lastPathComponent).xml")
    }

    static func canonical(_ xml: String) throws -> String {
        let doc = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        guard let root = doc.rootElement() else { throw CotParseError.notAnEvent(root: "") }
        var out = ""
        write(root, into: &out, depth: 0)
        return out
    }

    private static func write(_ e: XMLElement, into out: inout String, depth: Int) {
        let name = e.name ?? ""
        out += String(repeating: "  ", count: depth) + "<" + name
        let attributes = (e.attributes ?? []).map { ($0.name ?? "", $0.stringValue ?? "") }.sorted { $0.0 < $1.0 }
        for (key, value) in attributes {
            let shown = name == "point" ? Double(value).map { String(format: "%.7f", $0) } ?? value : value
            out += " \(key)=\(shown.debugDescription)"
        }
        out += ">\n"
        let children = (e.children ?? []).compactMap { $0 as? XMLElement }
        if children.isEmpty {
            let text = (e.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out += String(repeating: "  ", count: depth + 1) + text.debugDescription + "\n" }
        }
        for c in children { write(c, into: &out, depth: depth + 1) }
    }

    /// A self spec: key=value lines, # comments (java.util.Properties' subset).
    static func properties(_ url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            result[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
        }
        return result
    }

    static func selfEvent(_ spec: [String: String]) throws -> CotEvent {
        func number(_ key: String) -> Double? { spec[key].flatMap(Double.init) }
        var s = SelfEvent(uid: spec["uid"]!, callsign: spec["callsign"]!,
                          group: GroupDetail(team: spec["team"], role: spec["role"] ?? GroupDetail.defaultRole,
                                             customRole: spec["customRole"],
                                             customRoleAbbreviation: spec["customRoleAbbreviation"],
                                             displayAsSymbologyGraphic: spec["typeIcon"] == "true"))
        s.type = spec["type"] ?? SelfEvent.defaultType
        s.endpoint = spec["endpoint"]
        s.remarks = spec["remarks"]
        if let source = spec["source"] {
            let point = CotPoint(lat: number("lat")!, lon: number("lon")!, hae: number("hae") ?? CotPoint.unknown,
                                 ce: number("ce") ?? CotPoint.unknown, le: number("le") ?? CotPoint.unknown)
            s.location = .init(point: point, source: source == "manual" ? .manual : .provider)
        }
        s.track = Track(speed: number("speed") ?? 0, course: number("course") ?? 0)
        s.battery = Int(spec["battery"] ?? "100")!
        s.takv = TakVersion(device: spec["takv.device"]!, platform: spec["takv.platform"]!,
                            os: spec["takv.os"]!, version: spec["takv.version"]!)
        let time = Cot.parseTime(spec["time"]!)!
        return s.event(at: time, stale: number("staleSeconds")!)
    }

    /// A point spec: the palette entry its iconsetpath names, placed where
    /// and by whom the spec says, then given its remarks and address as the
    /// inspector gives them.
    static func placedPoint(_ spec: [String: String]) throws -> (PointKind, CotEvent) {
        guard let kind = PointKind.all.first(where: { $0.iconsetPath == spec["iconsetpath"] }) else {
            throw CotParseError.notAnEvent(root: spec["iconsetpath"] ?? "")
        }
        func number(_ key: String) -> Double? { spec[key].flatMap(Double.init) }
        let time = Cot.parseTime(spec["time"]!)!
        let point = CotPoint(lat: number("lat")!, lon: number("lon")!, hae: number("hae") ?? CotPoint.unknown)
        let author = Author(uid: spec["author.uid"]!, type: spec["author.type"]!, callsign: spec["author.callsign"]!,
                            time: time)
        var event = PlacedPoint.event(uid: spec["uid"]!, kind: kind, callsign: spec["callsign"]!,
                                      at: .clicked(point, altitudeSource: spec["altsrc"]), author: author, now: time)
        if let remarks = spec["remarks"] { event.setRemarks(remarks) }
        if let text = spec["address.text"] {
            event.setAddress(AddressDetail(text: text, geocoder: spec["address.geocoder"] ?? "unknown",
                                           time: spec["address.time"]))
        }
        return (kind, event)
    }
}
