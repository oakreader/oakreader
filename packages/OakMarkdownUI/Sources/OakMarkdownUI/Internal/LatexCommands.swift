import Foundation

/// Commands models write that SwiftUIMath does not know, rewritten into ones it does.
///
/// ChatGPT's `MTMathAtomFactory+CustomCommands.swift` patches iosMath with a typed
/// table (`alias`, `command`, `noop`, `binaryOperator`, `largeOperator`). SwiftUIMath's
/// tables are internal Swift statics, so the same table is applied to the source
/// before parsing instead. Each entry keeps the formula on the native path; a command
/// missing here sends the whole formula to the slower KaTeX fallback.
enum LatexCommands {
    enum Kind {
        /// Another command or symbol that draws the same thing.
        case alias(String)
        /// Drop the command and keep what follows. `\bigl(` becomes `(`: the delimiter
        /// is drawn at its natural size, which reads correctly in inline math.
        case noop
        /// `\name{…}` becomes `replacement{…}`.
        case command(String)
    }

    static let table: [String: Kind] = [
        "dots": .alias(#"\ldots"#),
        "dotsc": .alias(#"\ldots"#),
        "dotso": .alias(#"\ldots"#),
        "dotsb": .alias(#"\cdots"#),
        "dotsm": .alias(#"\cdots"#),
        "dotsi": .alias(#"\cdots"#),
        "lvert": .alias("|"),
        "rvert": .alias("|"),
        "lVert": .alias(#"\|"#),
        "rVert": .alias(#"\|"#),
        "vdash": .alias("⊢"),
        "dashv": .alias("⊣"),
        "models": .alias("⊨"),
        "leftrightharpoons": .alias("⇌"),
        "rightleftharpoons": .alias("⇌"),
        "coloneqq": .alias(":="),
        "eqqcolon": .alias("=:"),
        "big": .noop, "Big": .noop, "bigg": .noop, "Bigg": .noop,
        "bigl": .noop, "Bigl": .noop, "biggl": .noop, "Biggl": .noop,
        "bigr": .noop, "Bigr": .noop, "biggr": .noop, "Biggr": .noop,
        "bigm": .noop, "Bigm": .noop, "biggm": .noop, "Biggm": .noop,
        "operatorname": .command(#"\mathrm"#),
        "operatorname*": .command(#"\mathrm"#),
    ]

    // A command name is letters; `\operatorname*` alone takes a star. Whatever
    // follows the name is copied through, so spacing and stray stars survive.
    private static let commandRegex = try! NSRegularExpression(pattern: #"\\([A-Za-z]+)(\*?)"#)

    static func rewrite(_ latex: String) -> String {
        guard latex.contains("\\") else { return latex }
        let ns = latex as NSString
        let out = NSMutableString()
        var cursor = 0
        for match in commandRegex.matches(in: latex, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            let starred = match.range(at: 2).length > 0 && table[name + "*"] != nil
            guard let kind = starred ? table[name + "*"] : table[name] else { continue }
            out.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            switch kind {
            case .alias(let target), .command(let target): out.append(target)
            case .noop: break
            }
            cursor = starred ? NSMaxRange(match.range) : NSMaxRange(match.range(at: 1))
        }
        out.append(ns.substring(from: cursor))
        return out as String
    }
}
