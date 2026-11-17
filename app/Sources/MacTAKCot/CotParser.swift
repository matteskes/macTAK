// CotParser.swift — CoT XML into a CotEvent (G3.4).
//
// Follows the kernel's CotContentHandler at the pin, so a peer's event reads
// here as it reads on Android:
//   - uid and type are required; lat and lon are required when a point is
//     there; hae, ce and le that are missing, unparseable or NaN are unknown
//   - a missing or unreadable time, start or stale is now
//   - only the first <detail> counts, and everything under it is kept as a
//     tree, unknown elements included
//   - a leaf keeps its text, trimmed; an element with children keeps none.
// Unlike the kernel, a DOCTYPE refuses the whole event (no entity expansion
// at all, as G1's CotEvent did: dev/g1/headless CotEventSelfTest).

import Foundation

public enum CotParseError: Error, Equatable, CustomStringConvertible {
    case doctype
    case notAnEvent(root: String)
    case missing(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .doctype: return "CoT with a DOCTYPE is refused"
        case let .notAnEvent(root): return "not a CoT event (root <\(root)>)"
        case let .missing(what): return "CoT event without \(what)"
        case let .malformed(why): return "malformed CoT: \(why)"
        }
    }
}

extension CotEvent {
    public static func parse(_ xml: String, now: Date = Date()) throws -> CotEvent {
        if xml.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil { throw CotParseError.doctype }
        let reader = Reader(now: now)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let parsed = parser.parse()
        if let failure = reader.failure { throw failure }
        guard parsed else {
            throw CotParseError.malformed(parser.parserError.map { "\($0.localizedDescription)" } ?? "unknown")
        }
        guard let event = reader.event else { throw CotParseError.notAnEvent(root: "") }
        return event
    }
}

private final class Reader: NSObject, XMLParserDelegate {
    let now: Date
    var event: CotEvent?
    var failure: CotParseError?
    private var depth = 0
    /// The open elements under <detail>, <detail> itself first.
    private var details: [CotDetail] = []
    private var text = ""
    private var detailDone = false

    init(now: Date) { self.now = now }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        text = ""
        if depth == 1 {
            guard name == "event" else { return fail(parser, .notAnEvent(root: name)) }
            startEvent(parser, attributes)
        } else if !details.isEmpty {
            details.append(detail(name, attributes))
        } else if depth == 2, name == "point" {
            startPoint(parser, attributes)
        } else if depth == 2, name == "detail", !detailDone {
            details.append(detail(name, attributes))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        guard var done = details.popLast() else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if done.children.isEmpty, !trimmed.isEmpty { done.innerText = trimmed }
        text = ""
        if details.isEmpty {
            event?.detail = done
            detailDone = true
        } else {
            details[details.count - 1].add(done)
        }
    }

    private func startEvent(_ parser: XMLParser, _ a: [String: String]) {
        guard let uid = a["uid"], !uid.isEmpty else { return fail(parser, .missing("uid")) }
        guard let type = a["type"], !type.isEmpty else { return fail(parser, .missing("type")) }
        let time = a["time"].flatMap(Cot.parseTime) ?? now
        var e = CotEvent(uid: uid, type: type, time: time,
                         start: a["start"].flatMap(Cot.parseTime) ?? now,
                         stale: a["stale"].flatMap(Cot.parseTime) ?? now,
                         how: a["how"] ?? "")
        if let v = a["version"], !v.isEmpty { e.version = v }
        e.opex = a["opex"]; e.qos = a["qos"]; e.access = a["access"]
        e.caveat = a["caveat"]; e.releasableTo = a["releasableTo"]
        event = e
    }

    private func startPoint(_ parser: XMLParser, _ a: [String: String]) {
        guard let lat = a["lat"].flatMap(Double.init) else { return fail(parser, .missing("point lat")) }
        guard let lon = a["lon"].flatMap(Double.init) else { return fail(parser, .missing("point lon")) }
        func optional(_ key: String) -> Double { a[key].flatMap(Double.init) ?? CotPoint.unknown }
        event?.point = CotPoint(lat: lat, lon: lon, hae: optional("hae"), ce: optional("ce"), le: optional("le"))
    }

    /// XMLParser hands attributes over as a dictionary, which loses their
    /// order; the kernel loses it too (a HashMap), so sorting by name costs
    /// nothing a peer could see and keeps the result stable.
    private func detail(_ name: String, _ a: [String: String]) -> CotDetail {
        var d = CotDetail(name)
        for key in a.keys.sorted() { d[key] = a[key] }
        return d
    }

    private func fail(_ parser: XMLParser, _ error: CotParseError) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }
}
