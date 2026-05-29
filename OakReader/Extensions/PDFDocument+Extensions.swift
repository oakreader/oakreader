import PDFKit
import AppKit

extension PDFDocument {
    var allPages: [PDFPage] {
        (0..<pageCount).compactMap { page(at: $0) }
    }

    func pages(in range: IndexSet) -> [PDFPage] {
        range.compactMap { page(at: $0) }
    }

    func totalAnnotationCount() -> Int {
        allPages.reduce(0) { $0 + $1.annotations.count }
    }

    func extractPages(_ indices: IndexSet) -> PDFDocument {
        let newDoc = PDFDocument()
        var insertIndex = 0
        for pageIndex in indices.sorted() {
            guard let page = page(at: pageIndex) else { continue }
            if let copiedPage = page.copy() as? PDFPage {
                newDoc.insert(copiedPage, at: insertIndex)
                insertIndex += 1
            }
        }
        return newDoc
    }

    func appendDocument(_ other: PDFDocument) {
        for i in 0..<other.pageCount {
            guard let page = other.page(at: i) else { continue }
            if let copiedPage = page.copy() as? PDFPage {
                insert(copiedPage, at: pageCount)
            }
        }
    }

    func fileSizeEstimate() -> Int64 {
        guard let data = dataRepresentation() else { return 0 }
        return Int64(data.count)
    }

    func searchAll(_ query: String, options: NSString.CompareOptions = [.caseInsensitive]) -> [PDFSelection] {
        findString(query, withOptions: options) ?? []
    }

    /// Search tolerant of extra words the model wraps around a verbatim quote.
    /// `findString` only matches exact substrings, but a citation's `text=` is often a
    /// paraphrase (e.g. "agent verification framework with Guideline-grounded Evidence
    /// Accumulation") whose verbatim core is just a few of those words. We try the exact
    /// phrase first, then progressively shorter contiguous word-windows (longest first),
    /// returning the first that matches. Matches on `preferredPage` (0-based) are floated
    /// to the front so a citation lands on its cited page when the phrase recurs.
    func searchTolerant(_ query: String, preferredPage: Int? = nil) -> [PDFSelection] {
        let opts: NSString.CompareOptions = [.caseInsensitive]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        func ordered(_ results: [PDFSelection]) -> [PDFSelection] {
            guard let preferredPage, results.count > 1 else { return results }
            let onPage = results.filter { sel in
                sel.pages.first.map { index(for: $0) == preferredPage } ?? false
            }
            return onPage.isEmpty ? results : onPage
        }

        // Order by cited page, then grow each hit out to its enclosing sentence so the
        // highlight is a readable passage rather than a bare fragment.
        func finalize(_ results: [PDFSelection]) -> [PDFSelection] {
            ordered(results).map { $0.expandedToSentence() }
        }

        // 1. Exact phrase.
        let exact = findString(trimmed, withOptions: opts)
        if !exact.isEmpty { return finalize(exact) }

        // 2. Longest contiguous word-window that occurs verbatim.
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > 1 {
            var attempts = 0
            let maxAttempts = 60
            contiguous: for windowLen in stride(from: words.count - 1, through: 2, by: -1) {
                for start in 0...(words.count - windowLen) {
                    let phrase = words[start..<(start + windowLen)].joined(separator: " ")
                    guard phrase.count >= 8 else { continue }   // skip undistinctive fragments
                    attempts += 1
                    if attempts > maxAttempts { break contiguous }
                    let hits = findString(phrase, withOptions: opts)
                    if !hits.isEmpty { return finalize(hits) }
                }
            }
        }

        // 3. Fuzzy fallback. AI-generated citations are often not a verbatim quote — words
        //    get reordered, dropped, paraphrased, or mangled by OCR/hyphenation. Fall back
        //    to the page region with the best token overlap so we still land somewhere sane.
        if let fuzzy = fuzzyMatch(trimmed, preferredPage: preferredPage) {
            return [fuzzy.expandedToSentence()]
        }
        return []
    }

    /// Best fuzzy match for `query`: the page region whose words overlap the query most,
    /// scored over a sliding token window. Tolerant of reordering, missing/extra words and
    /// OCR noise (unlike `findString`, which needs an exact substring). Distinctive words
    /// count more than stopwords; `minScore` is the fraction of the query's weighted tokens
    /// that must be present for a region to qualify, so a wholly bogus citation matches
    /// nothing instead of highlighting a random spot. `preferredPage` (0-based) is searched
    /// first and wins outright on a strong hit.
    func fuzzyMatch(_ query: String, preferredPage: Int? = nil, minScore: Double = 0.55) -> PDFSelection? {
        let qTokens = Self.oakTokens(in: query).map { $0.text }
        let qSet = Set(qTokens)
        guard qSet.count >= 2 else { return nil }
        let qWeightTotal = qSet.reduce(0.0) { $0 + oakWeight($1) }
        guard qWeightTotal > 0 else { return nil }

        let order: [Int]
        if let p = preferredPage, (0..<pageCount).contains(p) {
            order = [p] + (0..<pageCount).filter { $0 != p }
        } else {
            order = Array(0..<pageCount)
        }

        let windowLen = qTokens.count + max(2, qSet.count / 2)   // allow a few extra words
        var best: OakFuzzyHit?

        for pageIndex in order {
            guard let page = page(at: pageIndex), let text = page.string else { continue }
            let toks = Self.oakTokens(in: text)
            let n = toks.count
            if n == 0 { continue }
            for i in 0..<n {
                let end = min(i + windowLen, n)
                var matched = Set<String>()
                var firstPos = -1, lastPos = -1
                for j in i..<end where qSet.contains(toks[j].text) {
                    matched.insert(toks[j].text)
                    if firstPos < 0 { firstPos = j }
                    lastPos = j
                }
                guard firstPos >= 0 else { continue }
                let score = matched.reduce(0.0) { $0 + oakWeight($1) } / qWeightTotal
                let span = lastPos - firstPos
                if best == nil || score > best!.score || (score == best!.score && span < best!.span) {
                    let startLoc = toks[firstPos].range.location
                    let endLoc = toks[lastPos].range.location + toks[lastPos].range.length
                    best = OakFuzzyHit(score: score, span: span,
                                       range: NSRange(location: startLoc, length: endLoc - startLoc),
                                       page: page)
                }
            }
            // A strong hit on the cited page wins immediately — no need to scan the rest.
            if let b = best, preferredPage == pageIndex, b.score >= 0.85 {
                return b.page.selection(for: b.range)
            }
        }

        guard let b = best, b.score >= minScore else { return nil }
        return b.page.selection(for: b.range)
    }

    private struct OakToken { let text: String; let range: NSRange }
    private struct OakFuzzyHit { let score: Double; let span: Int; let range: NSRange; let page: PDFPage }

    /// Lowercased word tokens of `s` with their character ranges, using Foundation's
    /// Unicode word segmentation (strips punctuation/whitespace, no regex needed).
    private static func oakTokens(in s: String) -> [OakToken] {
        guard !s.isEmpty else { return [] }
        var toks: [OakToken] = []
        s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: .byWords) { sub, range, _, _ in
            guard let sub, !sub.isEmpty else { return }
            toks.append(OakToken(text: sub.lowercased(), range: NSRange(range, in: s)))
        }
        return toks
    }

    func textContent() -> String {
        allPages.compactMap { $0.string }.joined(separator: "\n\n")
    }

    func flattenAnnotations() {
        for i in 0..<pageCount {
            guard let page = page(at: i) else { continue }
            let annotations = page.annotations
            for annotation in annotations {
                // Skip widget annotations (form fields) and links
                if annotation.type == "Widget" || annotation.type == "Link" { continue }
                // Flatten by rendering annotation into page content
                page.removeAnnotation(annotation)
            }
        }
    }

    func copyDocument() -> PDFDocument? {
        guard let data = dataRepresentation() else { return nil }
        return PDFDocument(data: data)
    }
}

extension PDFSelection {
    /// Returns a new selection grown outward from this one to the enclosing sentence
    /// (bounded by `. ! ?`, line breaks, or `maxRadius` characters on each side), so a
    /// citation highlights a readable passage rather than a bare matched fragment.
    /// Falls back to `self` if the page text or range can't be resolved.
    func expandedToSentence(maxRadius: Int = 320) -> PDFSelection {
        guard let page = pages.first, let pageText = page.string else { return self }
        let selString = string ?? ""
        guard !selString.isEmpty else { return self }
        let ns = pageText as NSString
        let match = ns.range(of: selString, options: [.caseInsensitive])
        guard match.location != NSNotFound else { return self }

        let enders = CharacterSet(charactersIn: ".!?\n\r")
        let ws = CharacterSet.whitespacesAndNewlines
        let leftLimit = max(0, match.location - maxRadius)
        let rightLimit = min(ns.length, match.location + match.length + maxRadius)

        // Walk left to the start of the sentence.
        var start = match.location
        while start > leftLimit {
            guard let s = Unicode.Scalar(ns.character(at: start - 1)), !enders.contains(s) else { break }
            start -= 1
        }
        // Walk right to (and including) the sentence terminator.
        var end = match.location + match.length
        while end < rightLimit {
            let isEnder = Unicode.Scalar(ns.character(at: end)).map { enders.contains($0) } ?? false
            end += 1
            if isEnder { break }
        }
        // Trim leading whitespace the left-walk picked up.
        while start < match.location,
              let s = Unicode.Scalar(ns.character(at: start)), ws.contains(s) {
            start += 1
        }

        let range = NSRange(location: start, length: max(0, end - start))
        return page.selection(for: range) ?? self
    }
}

// MARK: - Fuzzy-match helpers

/// Common words that carry little identifying signal, so they shouldn't let a region win
/// on overlap alone (a citation full of "the/of/and" matches isn't a real hit).
private let oakStopwords: Set<String> = [
    "the", "a", "an", "of", "and", "or", "to", "in", "on", "for", "with", "is", "are",
    "was", "were", "be", "by", "that", "this", "it", "as", "at", "from", "its", "their",
    "these", "those", "which", "we", "our", "they", "but", "not", "than", "then", "so",
    "such", "can", "may", "into", "over", "via", "using"
]

private func oakWeight(_ token: String) -> Double {
    oakStopwords.contains(token) ? 0.25 : 1.0
}
