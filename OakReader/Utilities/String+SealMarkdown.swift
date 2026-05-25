import Foundation

extension String {
    /// Closes unmatched markdown markers in streaming content to prevent jitter.
    /// When the model streams `**bold`, the unclosed `**` causes the parser to
    /// alternate between literal and bold rendering. By appending the missing
    /// closing markers, the parser renders consistently on every frame.
    ///
    /// Pipeline order matters — process from most specific to least specific:
    /// code fences → inline code → bold+italic → bold → italic → strikethrough → math
    func sealIncompleteMarkdown() -> String {
        guard !isEmpty else { return self }
        var s = self

        // 1. Code fences — if odd count of ```, close the fence.
        //    Everything inside a code fence is literal, so return early.
        if s.countNonOverlapping("```") % 2 == 1 {
            if !s.hasSuffix("\n") { s += "\n" }
            s += "```"
            return s
        }

        // 2. Inline code — count single backticks (not part of ```).
        //    If odd, close it and return (markers inside code spans are literal).
        let withoutFences = s.replacingOccurrences(of: "```", with: "   ")
        if withoutFences.filter({ $0 == "`" }).count % 2 == 1 {
            s += "`"
            return s
        }

        // 3. Bold+italic *** (must check before ** and *)
        let tripleStarCount = s.countNonOverlapping("***")
        if tripleStarCount % 2 == 1 {
            s += "***"
            return s
        }

        // 4. Bold ** (count ** that aren't part of ***)
        let withoutTriple = s.replacingOccurrences(of: "***", with: "   ")
        if withoutTriple.countNonOverlapping("**") % 2 == 1 {
            s += "**"
        }

        // 5. Italic * (single *, not part of ** or ***)
        let withoutDouble = withoutTriple.replacingOccurrences(of: "**", with: "  ")
        if withoutDouble.filter({ $0 == "*" }).count % 2 == 1 {
            s += "*"
        }

        // 6. Strikethrough ~~
        if s.countNonOverlapping("~~") % 2 == 1 {
            s += "~~"
        }

        // 7. Math $$ — display math requires $$ on its own line.
        //    If the unclosed $$ has a newline after it (block math), close
        //    with \n$$ so the parser sees a proper display block.
        if s.countNonOverlapping("$$") % 2 == 1 {
            // Find the last (unclosed) $$
            if let lastDollar = s.range(of: "$$", options: .backwards) {
                let afterDollar = s[lastDollar.upperBound...]
                if afterDollar.contains("\n") {
                    // Block math — close on a new line
                    if !s.hasSuffix("\n") { s += "\n" }
                    s += "$$"
                } else {
                    // Inline-style $$ — close on same line
                    s += "$$"
                }
            }
        }

        return s
    }

    /// Counts non-overlapping occurrences of `pattern` in the string.
    func countNonOverlapping(_ pattern: String) -> Int {
        var count = 0
        var searchRange = startIndex..<endIndex
        while let range = range(of: pattern, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<endIndex
        }
        return count
    }
}
