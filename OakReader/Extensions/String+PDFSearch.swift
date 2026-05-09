import Foundation

extension String {
    func normalizedForSearch() -> String {
        // Normalize unicode, fold case, strip diacritics
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    func ranges(of searchString: String, options: String.CompareOptions = [.caseInsensitive]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchRange = startIndex..<endIndex
        while let range = self.range(of: searchString, options: options, range: searchRange) {
            ranges.append(range)
            searchRange = range.upperBound..<endIndex
        }
        return ranges
    }

    // Simple diff algorithm for text comparison
    static func diff(_ old: String, _ new: String) -> [DiffResult] {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)

        // LCS-based diff
        let m = oldLines.count
        let n = newLines.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if oldLines[i - 1] == newLines[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = Swift.max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var results: [DiffResult] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
                results.append(.unchanged(oldLines[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                results.append(.added(newLines[j - 1]))
                j -= 1
            } else if i > 0 {
                results.append(.removed(oldLines[i - 1]))
                i -= 1
            }
        }

        return results.reversed()
    }

    /// Word-level diff using LCS algorithm (same approach as `diff()` but on tokens instead of lines).
    static func wordDiff(_ old: String, _ new: String) -> [DiffResult] {
        let oldTokens = tokenizeByWhitespace(old)
        let newTokens = tokenizeByWhitespace(new)

        // Guard: if token count product is too large, fall back to simple full replacement
        if oldTokens.count * newTokens.count > 250_000 {
            return [.removed(old), .added(new)]
        }

        let m = oldTokens.count
        let n = newTokens.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...Swift.max(m, 1) {
            guard i <= m else { break }
            for j in 1...Swift.max(n, 1) {
                guard j <= n else { break }
                if oldTokens[i - 1] == newTokens[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = Swift.max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var results: [DiffResult] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldTokens[i - 1] == newTokens[j - 1] {
                results.append(.unchanged(oldTokens[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                results.append(.added(newTokens[j - 1]))
                j -= 1
            } else if i > 0 {
                results.append(.removed(oldTokens[i - 1]))
                i -= 1
            }
        }

        return results.reversed()
    }

    /// Tokenize a string by whitespace boundaries, preserving whitespace tokens
    /// so that newlines and spacing reconstruct correctly.
    private static func tokenizeByWhitespace(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWhitespace = false

        for char in text {
            let charIsWhitespace = char.isWhitespace
            if charIsWhitespace != inWhitespace && !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            current.append(char)
            inWhitespace = charIsWhitespace
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    enum DiffResult: Equatable {
        case unchanged(String)
        case added(String)
        case removed(String)

        var text: String {
            switch self {
            case .unchanged(let s), .added(let s), .removed(let s): return s
            }
        }
    }
}
