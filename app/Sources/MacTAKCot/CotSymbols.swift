// CotSymbols.swift — a CoT type's MIL-STD-2525C symbol code (G3.7), ported
// from ATAK 5.5's CotUtils.mil2525cFromCotType (takkernel `shared`).
//
// The code is built from the type: the affiliation, then one letter per
// level from the battle dimension on, with "p" (present) after it, padded
// with "-" to 15 (an installation, "g…i", gets "h" in position 11). Then the
// renderer is asked whether it draws it. If not, the type's parent (the type
// less its last "-x") is tried, and the answer is cached for the type. So
// "a-f-G-U-C-I-z" (no such symbol) draws as "a-f-G-U-C-I", infantry.
//
// Kept as 5.5 has them:
//   - the result is lower case ("sfgpuci--------"); 5.5 upper-cases it only
//     when it asks the renderer
//   - a type the renderer can't draw at any level, and one with no "-"
//     left, returns the code it built anyway (uncached)
//   - anything not starting "a" (or shorter than 3) maps to "".
// The golden test (dev/g3/test/symbol-golden, make test-symbol-golden) holds
// it to the kernel's own mapping.

/// A CoT type's 2525C code, as 5.5 maps it. One per renderer: `canRender` is
/// asked about upper-case 15-character codes and its answers are cached.
public final class CotSymbols {
    private let canRender: (String) -> Bool
    private var cache: [String: String] = [:]

    /// `canRender`: whether the renderer draws this (upper-case) code; the
    /// app passes `EngineBridge.canRenderSymbol`.
    public init(canRender: @escaping (String) -> Bool) {
        self.canRender = canRender
    }

    public func mil2525C(fromCotType type: String) -> String {
        if let known = cache[type] { return known }
        let t = Array(type)
        guard t.first == "a", t.count > 2 else { return "" }

        var code = Self.affiliation(t[2])
        var x = 4
        while x < t.count {
            code += String(t[x]).lowercased()
            if x == 4 { code += "p" }
            x += 2
        }
        var c = Array(code)
        for x in c.count..<max(c.count, Self.length) {
            c.append(x == 10 && c[2] == "g" && c[4] == "i" ? "h" : "-")
        }
        code = String(c)

        if !canRender(code.uppercased()) {
            guard let dash = type.lastIndex(of: "-") else { return code }
            let parent = mil2525C(fromCotType: String(type[..<dash]))
            cache[type] = parent
            return parent
        }
        cache[type] = code
        return code
    }

    /// A 2525C code's length.
    static let length = 15

    /// The code's first two letters: scheme "s" (warfighting) and the
    /// affiliation, from the CoT type's third character.
    private static func affiliation(_ c: Character) -> String {
        switch c {
        case "f", "a": "sf"
        case "n": "sn"
        case "s", "j", "k", "h": "sh"
        default: "su"
        }
    }
}
