import Foundation

/// Rewrites chunk-ID citations the model emits — `oak://cite/{citeKey}?c=<chunkId>&text=…`,
/// where the model references a retrieved chunk by its id — into the standard
/// `?page=&text=` anchors the rest of the app understands.
///
/// The page comes from the chunk (always correct); the `?text=` quote is kept only
/// if it actually appears in that chunk's ground-truth text, otherwise it is dropped
/// to a page-only citation — so a citation never produces a broken highlight. A `?c=`
/// whose chunk can't be found becomes a bare citation rather than an unparseable URL.
///
/// Resolving to a durable `?page=&text=` (rather than leaving the volatile rowid `?c=`
/// in chat history) is deliberate: FTS rowids change on re-index, so a persisted `?c=`
/// would rot. See `docs/backlog/citation-grounding-redesign.md`.
///
/// Shared by `ResearchTool` (resolves before returning to the parent) and the main
/// chat (`ChatViewModel`, resolves when an assistant turn settles).
enum ChunkCitationResolver {

    /// Resolve every `?c=<id>` citation in `answer` against the FTS chunk store.
    /// Cheap no-op when the text contains no `?c=`.
    static func resolve(in answer: String, using service: FTSIndexService) async -> String {
        guard answer.contains("?c="),
              let regex = try? NSRegularExpression(
                pattern: "oak://cite/[A-Za-z0-9_.:\\-]+\\?[^)\\s\\]\"'<>]*")
        else { return answer }

        let ns = answer as NSString
        let matches = regex.matches(in: answer, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return answer }

        let ids = matches.compactMap { chunkId(inURL: ns.substring(with: $0.range)) }
        guard !ids.isEmpty else { return answer }
        let chunkMap = await service.chunks(byIds: ids)

        // Rewrite back-to-front so earlier match ranges stay valid as we mutate.
        var out = answer
        for match in matches.reversed() {
            let urlStr = ns.substring(with: match.range)
            guard let rewritten = rewriteCitation(urlStr, chunks: chunkMap),
                  rewritten != urlStr,
                  let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: rewritten)
        }
        return out
    }

    /// Extract the `c=<id>` chunk id from an `oak://cite/...?...` URL, if present.
    private static func chunkId(inURL url: String) -> Int64? {
        guard let query = url.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.first == "c", kv.count == 2 { return Int64(kv[1]) }
        }
        return nil
    }

    /// Rewrite one citation URL, resolving `?c=` against `chunks`. Returns `nil` when
    /// there is no query to resolve (leave the URL untouched).
    private static func rewriteCitation(_ url: String, chunks: [Int64: FTSChunk]) -> String? {
        let parts = url.split(separator: "?", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let base = String(parts[0])

        var id: Int64?
        var rawText: String?
        for pair in parts[1].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "c": id = Int64(kv[1])
            case "text": rawText = kv[1]
            default: break
            }
        }
        guard let id else { return nil }   // not a chunk-id citation — leave alone

        var query: [String] = []
        if let chunk = chunks[id] {
            if let page = chunk.pageStart { query.append("page=\(page + 1)") }   // URL page is 1-based
            // Anchor on VERBATIM source text so the highlight reliably matches (PDF
            // search / DOM fuzzy-match). Keep the model's quote when it copied the
            // passage verbatim; otherwise (paraphrase, or no quote) fall back to the
            // chunk's first sentence — still real source text, never a dead link. This
            // is what makes HTML citations link back as reliably as PDF.
            if let rawText, quote(rawText, appearsIn: chunk.chunkText) {
                query.append("text=\(rawText)")
            } else if let sentence = firstSentence(of: chunk.chunkText) {
                query.append("text=\(encodeAnchor(sentence))")
            }
        }
        return query.isEmpty ? base : base + "?" + query.joined(separator: "&")
    }

    /// The chunk's leading sentence (verbatim), capped to a sane anchor length. Used as
    /// the fallback anchor when the model's quote can't be confirmed in the chunk.
    private static func firstSentence(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }
        let chars = Array(trimmed)
        let minLen = 15, maxLen = 200
        var endIdx = min(chars.count, maxLen)
        var i = 0
        while i < min(chars.count, maxLen) {
            let c = chars[i]
            if i + 1 >= minLen, c == "." || c == "!" || c == "?" || c == "\n" {
                endIdx = i + 1
                break
            }
            i += 1
        }
        let result = String(chars[0..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.count >= 8 ? result : nil
    }

    /// Percent-encode a plain-text anchor for a `text=` query value. `CitationAnchor`
    /// decodes both `+`→space and percent escapes; we encode spaces as `%20` and the
    /// reserved characters that would otherwise break URL/citation parsing.
    private static func encodeAnchor(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+%#?/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Whether a `+`/`%`-encoded `?text=` value actually appears in the chunk text,
    /// compared case-insensitively with whitespace runs collapsed (mirrors the
    /// highlighter's loose matching). Guards against trivially-short anchors.
    private static func quote(_ rawText: String, appearsIn chunkText: String) -> Bool {
        let decoded = rawText.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? rawText.replacingOccurrences(of: "+", with: " ")
        func norm(_ s: String) -> String {
            s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let needle = norm(decoded)
        guard needle.count >= 8 else { return false }
        return norm(chunkText).contains(needle)
    }
}
