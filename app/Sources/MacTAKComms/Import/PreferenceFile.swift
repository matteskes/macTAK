// PreferenceFile.swift — an ATAK .pref file (G3.2b).
//
// The format ATAK 5.5 writes and reads (PreferenceControl.loadSettings):
//
//   <preferences>
//     <preference version="1" name="cot_streams">
//       <entry key="count" class="class java.lang.Integer">1</entry>
//       <entry key="connectString0" class="class java.lang.String">host:8089:ssl</entry>
//       …
//     </preference>
//     <preference version="1" name="com.atakmap.app_preferences"> … </preference>
//   </preferences>
//
// Hardened like G1's importer (DataPackage.java): a DOCTYPE or entity
// declaration is refused before parsing, and external entities are never
// resolved, so a hostile package gets an error, not a file read.

import Foundation

struct PreferenceFile {
    /// One <preference> block: its name and its entries, in file order.
    struct Block {
        let name: String
        let entries: [String: String]
    }

    let blocks: [Block]

    func block(named name: String) -> Block? { blocks.first { $0.name == name } }

    init(data: Data, name: String) throws {
        let text = String(decoding: data, as: UTF8.self)
        let upper = text.uppercased()
        guard !upper.contains("<!DOCTYPE"), !upper.contains("<!ENTITY") else {
            throw ImportError("\(name): a DOCTYPE or entity declaration is not allowed")
        }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse() else {
            throw ImportError("\(name) is not valid XML: \(parser.parserError?.localizedDescription ?? "parse failed")")
        }
        guard reader.root == "preferences" else {
            throw ImportError("\(name): the root element is <\(reader.root ?? "none")>, not <preferences>")
        }
        blocks = reader.blocks
    }

    /// XMLParser's delegate: <preference> children of the root, and the
    /// keyed <entry> elements in each, values trimmed.
    private final class Reader: NSObject, XMLParserDelegate {
        var root: String?
        var blocks: [Block] = []
        private var depth = 0
        private var blockName: String?
        private var entries: [String: String] = [:]
        private var key: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            switch (depth, element) {
            case (1, _): root = element
            case (2, "preference"):
                blockName = attributes["name"] ?? ""
                entries = [:]
            case (3, "entry") where blockName != nil:
                key = attributes["key"].flatMap { $0.isEmpty ? nil : $0 }
                text = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if key != nil { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            switch (depth, element) {
            case (3, "entry"):
                if let key { entries[key] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                key = nil
            case (2, "preference"):
                if let blockName { blocks.append(Block(name: blockName, entries: entries)) }
                blockName = nil
            default: break
            }
            depth -= 1
        }
    }
}
