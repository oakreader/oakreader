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

    /// Locate a citation's quoted `text` and return a single selection for the matching
    /// passage. Robust to the ways PDF text and AI-generated quotes drift apart:
    ///   1. **Whitespace-tolerant whole-quote match** — collapses the runs of `\n`/spaces
    ///      that PDFKit inserts at every visual line break, so a quote that straddles two
    ///      lines still matches (plain `findString` misses these and is the #1 cause of a
    ///      citation that highlights the wrong fragment).
    ///   2. **Endpoint span** — match the quote's leading and trailing word-runs and take
    ///      the text between them, so a quote whose middle was paraphrased, re-hyphenated,
    ///      or OCR-garbled still anchors to the right passage (à la a Chrome text-fragment
    ///      `textStart,textEnd`).
    ///   3. **Fuzzy token-overlap fallback** for quotes that don't appear verbatim at all.
    /// The returned selection is **exactly** the matched passage — it is NOT grown to the
    /// enclosing sentence, so the highlight equals the quote shown in the citation hover
    /// card. `preferredPage` (0-based) is searched first so a citation lands on its page.
    func searchQuote(_ quote: String, preferredPage: Int? = nil) -> [PDFSelection] {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pageCount > 0 else { return [] }

        let order: [Int]
        if let p = preferredPage, (0..<pageCount).contains(p) {
            order = [p] + (0..<pageCount).filter { $0 != p }
        } else {
            order = Array(0..<pageCount)
        }

        for idx in order {
            guard let page = page(at: idx), let raw = page.string else { continue }
            let ns = raw as NSString
            let (norm, map) = Self.collapsedWhitespace(ns)
            // 1. Whole quote, tolerant of the line-break whitespace PDFKit injects.
            if let r = Self.rangeIn(norm, map, query: Self.collapsedQuery(trimmed), fromOriginal: 0),
               let sel = page.selection(for: r) {
                return [sel]
            }
            // 2. Endpoint span: leading words … trailing words.
            if let r = Self.endpointSpan(of: trimmed, norm: norm, map: map),
               let sel = page.selection(for: r) {
                return [sel]
            }
        }

        // 3. Fuzzy fallback (page-aware). AI quotes are often not verbatim — words get
        //    reordered, dropped, paraphrased, or mangled by OCR. Fall back to the page
        //    region with the best token overlap so we still land somewhere sane.
        if let fuzzy = fuzzyMatch(trimmed, preferredPage: preferredPage) {
            return [fuzzy]
        }
        return []
    }

    /// A whitespace-collapsed, index-mapped copy of `pageText`: every run of whitespace
    /// becomes a single space, and `map[i]` is the original UTF-16 index of the i-th
    /// character of the result. Lets us match across PDF line breaks yet still resolve the
    /// hit back to a real range on the page.
    private static func collapsedWhitespace(_ pageText: NSString) -> (norm: NSString, map: [Int]) {
        let len = pageText.length
        var chars = [unichar](); chars.reserveCapacity(len)
        var map = [Int](); map.reserveCapacity(len)
        var inWS = false
        for i in 0..<len {
            let c = pageText.character(at: i)
            let isWS = Unicode.Scalar(c).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
            if isWS {
                if !inWS { chars.append(32); map.append(i); inWS = true }   // single space
            } else {
                chars.append(c); map.append(i); inWS = false
            }
        }
        return (NSString(characters: chars, length: chars.count), map)
    }

    /// `s` with leading/trailing whitespace dropped and internal whitespace runs collapsed
    /// to single spaces — the query-side counterpart to `collapsedWhitespace`.
    private static func collapsedQuery(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Find `qNorm` (already whitespace-collapsed) in the collapsed page `norm`, at or after
    /// original index `fromOriginal`, and map the hit back to a range on the original page.
    /// Case-insensitive.
    private static func rangeIn(_ norm: NSString, _ map: [Int], query qNorm: String, fromOriginal: Int) -> NSRange? {
        guard !qNorm.isEmpty, norm.length > 0 else { return nil }
        let searchStart = fromOriginal > 0 ? (map.firstIndex { $0 >= fromOriginal } ?? norm.length) : 0
        guard searchStart < norm.length else { return nil }
        let hit = norm.range(of: qNorm, options: [.caseInsensitive],
                             range: NSRange(location: searchStart, length: norm.length - searchStart))
        guard hit.location != NSNotFound, hit.length > 0 else { return nil }
        let start = map[hit.location]
        let end = map[hit.location + hit.length - 1] + 1
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Match the quote's first and last few words and return the span between them, so a
    /// quote whose middle differs from the page (paraphrase, OCR/hyphenation noise) still
    /// anchors. Needs at least four words; caps the span so a bogus pairing can't highlight
    /// half the page.
    private static func endpointSpan(of quote: String, norm: NSString, map: [Int]) -> NSRange? {
        let words = quote.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 4 else { return nil }
        let k = min(3, words.count / 2)
        let head = collapsedQuery(words.prefix(k).joined(separator: " "))
        let tail = collapsedQuery(words.suffix(k).joined(separator: " "))
        guard let headR = rangeIn(norm, map, query: head, fromOriginal: 0),
              let tailR = rangeIn(norm, map, query: tail, fromOriginal: headR.location) else { return nil }
        let start = headR.location
        let end = tailR.location + tailR.length
        guard end > start, end - start <= 4000 else { return nil }
        return NSRange(location: start, length: end - start)
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
