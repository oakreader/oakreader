import CMarkGFM
import Foundation

/// Chunks text content for full-text indexing.
/// Two strategies: plain text (sentence-boundary) and markdown (heading-aware via cmark-gfm).
enum ContentChunker {

    struct Chunk {
        let text: String
        let type: String        // "abstract", "page", "section"
        let pageStart: Int?
        let pageEnd: Int?
    }

    // MARK: - Plain Text Chunking

    /// Split plain text into ~targetTokens chunks, breaking on sentence boundaries.
    /// Suitable for PDF pages, transcripts, and plain HTML.
    static func chunkPlainText(_ text: String, type: String = "section", targetTokens: Int = 500, pageStart: Int? = nil, pageEnd: Int? = nil) -> [Chunk] {
        let sentences = splitSentences(text)
        var chunks: [Chunk] = []
        var current = ""
        var currentTokens = 0

        for sentence in sentences {
            let sentenceTokens = estimateTokenCount(sentence)
            if currentTokens + sentenceTokens > targetTokens, !current.isEmpty {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunks.append(Chunk(text: trimmed, type: type, pageStart: pageStart, pageEnd: pageEnd))
                }
                current = ""
                currentTokens = 0
            }
            current += sentence
            currentTokens += sentenceTokens
        }

        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            chunks.append(Chunk(text: trimmed, type: type, pageStart: pageStart, pageEnd: pageEnd))
        }

        return chunks
    }

    // MARK: - Markdown Chunking (cmark-gfm AST)

    /// Split markdown into heading-aware sections using cmark-gfm AST.
    /// Each h1-h3 heading starts a new section. Long sections are sub-split on sentence boundaries.
    /// The heading text is prepended to each sub-chunk for context.
    static func chunkMarkdown(_ markdown: String, targetTokens: Int = 500) -> [Chunk] {
        let sections = extractMarkdownSections(markdown)
        var chunks: [Chunk] = []

        for section in sections {
            let sectionTokens = estimateTokenCount(section.body)
            if sectionTokens <= targetTokens {
                // Small enough — keep as one chunk with heading prefix
                let text = section.heading.isEmpty ? section.body : "\(section.heading)\n\n\(section.body)"
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chunks.append(Chunk(text: trimmed, type: "section", pageStart: nil, pageEnd: nil))
                }
            } else {
                // Sub-split long section by sentence boundaries
                let subChunks = chunkPlainText(section.body, type: "section", targetTokens: targetTokens)
                for sub in subChunks {
                    let text = section.heading.isEmpty ? sub.text : "\(section.heading)\n\n\(sub.text)"
                    chunks.append(Chunk(text: text, type: "section", pageStart: nil, pageEnd: nil))
                }
            }
        }

        return chunks
    }

    // MARK: - Markdown Section Extraction

    private struct MarkdownSection {
        let heading: String  // e.g. "## Methods" — empty for preamble
        let body: String     // text content under the heading
    }

    /// Walk the cmark-gfm AST to extract sections split by h1-h3 headings.
    private static func extractMarkdownSections(_ markdown: String) -> [MarkdownSection] {
        cmark_gfm_core_extensions_ensure_registered()

        guard let parser = cmark_parser_new(CMARK_OPT_UNSAFE) else {
            // Fallback: treat entire text as one section
            return [MarkdownSection(heading: "", body: markdown)]
        }
        defer { cmark_parser_free(parser) }

        let data = Array(markdown.utf8)
        cmark_parser_feed(parser, data, data.count)

        guard let document = cmark_parser_finish(parser) else {
            return [MarkdownSection(heading: "", body: markdown)]
        }
        defer { cmark_node_free(document) }

        var sections: [MarkdownSection] = []
        var currentHeading = ""
        var currentBody = ""

        // Walk top-level children of the document
        var node = cmark_node_first_child(document)
        while let current = node {
            let nodeType = cmark_node_get_type(current)

            if nodeType == CMARK_NODE_HEADING {
                let level = cmark_node_get_heading_level(current)
                if level >= 1 && level <= 3 {
                    // Save previous section
                    let trimmedBody = currentBody.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedBody.isEmpty || !currentHeading.isEmpty {
                        sections.append(MarkdownSection(heading: currentHeading, body: trimmedBody))
                    }
                    // Start new section
                    currentHeading = extractNodeText(current).trimmingCharacters(in: .whitespacesAndNewlines)
                    let prefix = String(repeating: "#", count: Int(level))
                    currentHeading = "\(prefix) \(currentHeading)"
                    currentBody = ""
                } else {
                    // h4-h6: include in current section body
                    currentBody += extractNodeText(current) + "\n\n"
                }
            } else {
                // Non-heading node: append text to current section
                currentBody += extractNodeText(current) + "\n\n"
            }

            node = cmark_node_next(current)
        }

        // Save final section
        let trimmedBody = currentBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty || !currentHeading.isEmpty {
            sections.append(MarkdownSection(heading: currentHeading, body: trimmedBody))
        }

        return sections
    }

    /// Recursively extract plain text from a cmark node and its children.
    private static func extractNodeText(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        var text = ""

        // Use an iterator for depth-first traversal
        guard let iter = cmark_iter_new(node) else { return "" }
        defer { cmark_iter_free(iter) }

        while true {
            let eventType = cmark_iter_next(iter)
            if eventType == CMARK_EVENT_DONE { break }
            if eventType != CMARK_EVENT_ENTER { continue }

            guard let current = cmark_iter_get_node(iter) else { continue }
            let currentType = cmark_node_get_type(current)

            if currentType == CMARK_NODE_TEXT || currentType == CMARK_NODE_CODE {
                if let literal = cmark_node_get_literal(current) {
                    text += String(cString: literal)
                }
            } else if currentType == CMARK_NODE_SOFTBREAK || currentType == CMARK_NODE_LINEBREAK {
                text += "\n"
            } else if currentType == CMARK_NODE_CODE_BLOCK {
                if let literal = cmark_node_get_literal(current) {
                    text += String(cString: literal)
                }
            }
        }

        return text
    }

    // MARK: - Utilities

    /// Rough token estimate: ~0.75 tokens per character for English text.
    static func estimateTokenCount(_ text: String) -> Int {
        max(1, Int(Double(text.count) * 0.75))
    }

    /// Sentence terminators, including CJK fullwidth punctuation (。！？；…、 and the
    /// fullwidth ．) so Chinese/Japanese text splits into real sentences rather than
    /// one ~500-token blob — required for sentence-level citation highlighting in CJK.
    private static let sentenceTerminators: Set<Character> = [
        ".", "?", "!", "。", "！", "？", "；", "…", "．"
    ]

    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if sentenceTerminators.contains(char) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences
    }
}
