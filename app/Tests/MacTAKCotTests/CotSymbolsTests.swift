// CotSymbolsTests.swift — G3.7's mapping, the Swift leg: CotSymbols maps
// every CoT type as takkernel's CotUtils.mil2525cFromCotType does.
//
// dev/g3/test/symbol-golden/expected comes from the kernel itself, with 5.5's
// 2525 providers on missioncommand's renderers (make test-symbol-golden
// checks it every CI run, and checks that the app's renderer draws exactly
// the codes the kernel's does, pixel for pixel). The renderer's answers come
// from renderable.tsv: a code the port asks about that the file lacks fails
// the test, since the kernel was never asked it.

import Foundation
import XCTest
@testable import MacTAKCot

final class CotSymbolsTests: XCTestCase {
    static let expected = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("dev/g3/test/symbol-golden/expected")

    /// Tab-separated rows of an expected file, '#' lines skipped.
    private func rows(_ name: String) throws -> [[String]] {
        try String(contentsOf: Self.expected.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") }
            .map { $0.components(separatedBy: "\t") }
    }

    private func kernelRenderer() throws -> (canRender: (String) -> Bool, unasked: () -> Set<String>) {
        var answers: [String: Bool] = [:]
        for row in try rows("renderable.tsv") { answers[row[0]] = row[1] == "true" }
        var unasked = Set<String>()
        return ({ code in
            guard let known = answers[code] else { unasked.insert(code); return false }
            return known
        }, { unasked })
    }

    func testEveryTypeMapsAsTheKernelMapsIt() throws {
        let renderer = try kernelRenderer()
        let symbols = CotSymbols(canRender: renderer.canRender)
        let cases = try rows("cot-to-2525c.tsv")
        XCTAssertGreaterThan(cases.count, 800)
        var wrong: [String] = []
        for row in cases {
            let got = symbols.mil2525C(fromCotType: row[0])
            if got != row[1] { wrong.append("\(row[0]): \(got), kernel \(row[1])") }
        }
        XCTAssertEqual(wrong, [], "\(wrong.count) of \(cases.count) types")
        XCTAssertEqual(renderer.unasked(), [], "codes the kernel was never asked")
    }

    func testFallsBackToTheDeepestTypeThatRenders() {
        let symbols = CotSymbols { $0 == "SFGPUCI--------" || $0 == "SFGP-----------" }
        XCTAssertEqual(symbols.mil2525C(fromCotType: "a-f-G-U-C-I-z"), "sfgpuci--------")
        XCTAssertEqual(symbols.mil2525C(fromCotType: "a-f-G-Q"), "sfgp-----------")
    }

    func testAsksTheRendererOncePerType() {
        var asked: [String] = []
        let symbols = CotSymbols { asked.append($0); return true }
        _ = symbols.mil2525C(fromCotType: "a-h-G-E-V")
        _ = symbols.mil2525C(fromCotType: "a-h-G-E-V")
        XCTAssertEqual(asked, ["SHGPEV---------"])
    }

    func testNonAtomsMapToNothing() {
        let symbols = CotSymbols { _ in true }
        for type in ["", "a", "a-", "b-m-p-s-p-i", "u-d-r"] {
            XCTAssertEqual(symbols.mil2525C(fromCotType: type), "", type)
        }
    }
}
