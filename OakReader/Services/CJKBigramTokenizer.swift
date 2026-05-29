import Foundation
import GRDB

/// FTS5 tokenizer that makes CJK text searchable.
///
/// `unicode61` treats an unspaced run of Han/kana as a single token, so keyword
/// search over Chinese/Japanese never matches mid-run (querying 学习 against a
/// chunk containing 机器学习 returns nothing). This wraps `unicode61` and re-emits
/// each CJK run as overlapping bigrams — 机器学习 → 机器 / 器学 / 学习 — so 2-char
/// queries match, while Latin/digit tokens pass through unchanged.
final class CJKBigramTokenizer: FTS5WrapperTokenizer {
    static let name = "cjk_bigram"

    let wrappedTokenizer: any FTS5Tokenizer

    init(db: Database, arguments: [String]) throws {
        wrappedTokenizer = try db.makeTokenizer(.unicode61())
    }

    func accept(
        token: String,
        flags: FTS5TokenFlags,
        for tokenization: FTS5Tokenization,
        tokenCallback: (String, FTS5TokenFlags) throws -> Void
    ) throws {
        var pendingLatin = ""
        var cjkRun: [Character] = []

        func flushLatin() throws {
            guard !pendingLatin.isEmpty else { return }
            try tokenCallback(pendingLatin, flags)
            pendingLatin = ""
        }
        func flushCJK() throws {
            if cjkRun.count == 1 {
                try tokenCallback(String(cjkRun[0]), [])
            } else if cjkRun.count >= 2 {
                for j in 0..<(cjkRun.count - 1) {
                    var bigram = ""
                    bigram.append(cjkRun[j])
                    bigram.append(cjkRun[j + 1])
                    try tokenCallback(bigram, [])
                }
            }
            cjkRun.removeAll(keepingCapacity: true)
        }

        for character in token {
            if Self.isCJK(character) {
                try flushLatin()
                cjkRun.append(character)
            } else {
                try flushCJK()
                pendingLatin.append(character)
            }
        }
        try flushLatin()
        try flushCJK()
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF,    // CJK Unified Ideographs
             0x3400...0x4DBF,    // CJK Extension A
             0x20000...0x2A6DF,  // CJK Extension B
             0x2A700...0x2EBEF,  // CJK Extensions C–F
             0xF900...0xFAFF,    // CJK Compatibility Ideographs
             0x3040...0x30FF,    // Hiragana + Katakana
             0xAC00...0xD7AF:    // Hangul syllables
            return true
        default:
            return false
        }
    }
}
