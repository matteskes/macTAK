// GoldenTests.swift — the Swift leg of the golden test (G3.4): a peer's
// event parsed and written back, and each self spec's self-SA, equal the
// expected files the kernel's leg also checks (Golden.swift).

import Foundation
import XCTest
@testable import MacTAKCot

final class GoldenTests: XCTestCase {
    func testParsedEventsWriteWhatTheKernelWrites() throws {
        let inputs = try Golden.inputs("parse", "xml")
        XCTAssertFalse(inputs.isEmpty, "no parse fixtures in \(Golden.root.path)")
        for input in inputs {
            let event = try CotEvent.parse(String(contentsOf: input, encoding: .utf8))
            try check(event.xml(), against: Golden.expectedURL("parse", input))
        }
    }

    func testSelfEventsAreWhatTheKernelBuilds() throws {
        let specs = try Golden.inputs("self", "properties")
        XCTAssertFalse(specs.isEmpty, "no self fixtures in \(Golden.root.path)")
        for spec in specs {
            let event = try Golden.selfEvent(Golden.properties(spec))
            XCTAssertTrue(event.isValid, spec.lastPathComponent)
            try check(event.xml(), against: Golden.expectedURL("self", spec))
        }
    }

    private func check(_ xml: String, against expected: URL, line: UInt = #line) throws {
        if Golden.writing {
            try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (xml + "\n").write(to: expected, atomically: true, encoding: .utf8)
            return
        }
        let want = try Golden.canonical(String(contentsOf: expected, encoding: .utf8))
        XCTAssertEqual(try Golden.canonical(xml), want, expected.lastPathComponent, line: line)
    }
}
