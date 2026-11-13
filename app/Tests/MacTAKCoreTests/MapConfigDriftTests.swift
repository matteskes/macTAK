// The Swift MapConfig and mactak.engine.MapConfig must name the same fields:
// EngineBridge.start sets each by name over JNI, so a field only Java has
// would silently keep its default, and one only Swift has fails at run time.

import Foundation
import XCTest
@testable import MacTAKCore

final class MapConfigDriftTests: XCTestCase {
    func testSwiftSetsEveryJavaField() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let java = try String(contentsOf: repo.appendingPathComponent(
            "dev/g2/render/src/mactak/engine/MapConfig.java"), encoding: .utf8)
        // `public <type> <name>` field declarations (not the constructor)
        let regex = try NSRegularExpression(pattern: #"^\s*public\s+(?!final\s+class|MapConfig\s*\()[\w\[\]]+\s+(\w+)\s*[;=]"#,
                                            options: .anchorsMatchLines)
        let range = NSRange(java.startIndex..., in: java)
        let javaNames = Set(regex.matches(in: java, range: range).map {
            String(java[Range($0.range(at: 1), in: java)!])
        })
        let swiftNames = Set(EngineBridge.javaFields(of: MapConfig()).map(\.0))
        XCTAssertFalse(javaNames.isEmpty, "found no fields in MapConfig.java")
        XCTAssertEqual(javaNames.subtracting(swiftNames), [], "Java fields Swift never sets")
        XCTAssertEqual(swiftNames.subtracting(javaNames), [], "Swift fields Java does not have")
    }

    func testGestureKindsMatchInputBridge() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let java = try String(contentsOf: repo.appendingPathComponent(
            "dev/g2/render/src/mactak/render/InputBridge.java"), encoding: .utf8)
        // the kinds are one declaration: `static final int DRAG = 0, SCROLL = 1, ...;`
        let decl = try XCTUnwrap(java.split(separator: "\n").first { $0.contains("static final int DRAG") })
        let declared = Set(decl.split(separator: ",").map { $0.replacingOccurrences(of: "static final int", with: "")
            .replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces) })
        for (name, kind) in [("DRAG", Gesture.drag), ("SCROLL", .scroll), ("WHEEL", .wheel),
                             ("MAGNIFY", .magnify), ("ROTATE", .rotate),
                             ("OPTION_DRAG", .optionDrag), ("DOUBLE_CLICK", .doubleClick)] {
            XCTAssertTrue(declared.contains("\(name) = \(kind.rawValue)"),
                          "InputBridge.\(name) should be \(kind.rawValue)")
        }
        XCTAssertEqual(declared.count, 7, "InputBridge declares kinds Swift's Gesture lacks")
    }
}
