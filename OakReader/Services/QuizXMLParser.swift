import Foundation

/// Parses LLM output containing interleaved Markdown text and `<quiz>` XML blocks.
///
/// Returns an array of `ContentSegment` for inline rendering in chat bubbles.
/// Quiz blocks are parsed into `QuizContent` values; surrounding text is preserved as-is.
enum QuizXMLParser {

    /// A segment of LLM output: either plain text (Markdown) or a parsed quiz block.
    enum ContentSegment {
        case text(String)
        case quiz(QuizContent)
    }

    // MARK: - Public API

    /// Check whether a string contains any `<quiz>` blocks.
    static func containsQuiz(_ text: String) -> Bool {
        text.range(of: #"<quiz\s"#, options: .regularExpression) != nil
    }

    /// Parse LLM output into interleaved text and quiz segments.
    static func parse(_ text: String) -> [ContentSegment] {
        var segments: [ContentSegment] = []
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var cursor = 0

        quizBlockPattern.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match else { return }
            let matchRange = match.range

            // Text before this quiz block
            if matchRange.location > cursor {
                let beforeRange = NSRange(location: cursor, length: matchRange.location - cursor)
                let before = ns.substring(with: beforeRange).trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty {
                    segments.append(.text(before))
                }
            }

            // Parse the quiz block
            let xmlContent = ns.substring(with: matchRange)
            if let quiz = parseQuizBlock(xmlContent) {
                segments.append(.quiz(quiz))
            }

            cursor = matchRange.location + matchRange.length
        }

        // Remaining text after last quiz block
        if cursor < ns.length {
            let remaining = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                segments.append(.text(remaining))
            }
        }

        return segments
    }

    // MARK: - Regex

    /// Matches `<quiz type="...">...</quiz>` blocks (non-greedy, dotall).
    // swiftlint:disable:next force_try
    private static let quizBlockPattern = try! NSRegularExpression(
        pattern: #"<quiz\s+type="(\w+)"[^>]*>(.*?)</quiz>"#,
        options: [.dotMatchesLineSeparators]
    )

    // MARK: - Block Parsing

    private static func parseQuizBlock(_ xml: String) -> QuizContent? {
        let ns = xml as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        guard let typeMatch = quizBlockPattern.firstMatch(in: xml, range: fullRange),
              typeMatch.range(at: 1).location != NSNotFound,
              typeMatch.range(at: 2).location != NSNotFound else {
            return nil
        }

        let type = ns.substring(with: typeMatch.range(at: 1))
        let body = ns.substring(with: typeMatch.range(at: 2))

        switch type {
        case "cloze":
            return parseCloze(body)
        case "choice":
            return parseChoice(body)
        case "flashcard":
            return parseFlashcard(body)
        case "occlusion":
            return parseOcclusion(body)
        case "matching":
            return parseMatching(body)
        case "ordering":
            return parseOrdering(body)
        default:
            return nil
        }
    }

    // MARK: - Type-Specific Parsers

    /// `<quiz type="cloze"><text>The {{c1::heart}} pumps blood</text><hint>organ</hint></quiz>`
    private static func parseCloze(_ body: String) -> QuizContent? {
        guard let text = extractTag("text", from: body), !text.isEmpty else { return nil }
        let hint = extractTag("hint", from: body)
        return .cloze(.init(text: text, hint: hint))
    }

    /// ```
    /// <quiz type="choice">
    ///   <question>What is 2+2?</question>
    ///   <option correct="true">4</option>
    ///   <option>3</option>
    ///   <option>5</option>
    ///   <explanation>Basic arithmetic</explanation>
    /// </quiz>
    /// ```
    private static func parseChoice(_ body: String) -> QuizContent? {
        guard let question = extractTag("question", from: body) else { return nil }

        let ns = body as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var choices: [String] = []
        var correctIndex = 0

        // swiftlint:disable:next force_try
        let optionPattern = try! NSRegularExpression(
            pattern: #"<option(\s+correct="true")?>(.*?)</option>"#,
            options: [.dotMatchesLineSeparators]
        )

        optionPattern.enumerateMatches(in: body, range: fullRange) { match, _, _ in
            guard let match else { return }
            let isCorrect = match.range(at: 1).location != NSNotFound
            let value = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if isCorrect { correctIndex = choices.count }
            choices.append(value)
        }

        guard !choices.isEmpty else { return nil }
        let explanation = extractTag("explanation", from: body)
        return .choice(.init(question: question, choices: choices, correctIndex: correctIndex, explanation: explanation))
    }

    /// `<quiz type="flashcard"><front>Q</front><back>A</back></quiz>`
    private static func parseFlashcard(_ body: String) -> QuizContent? {
        guard let front = extractTag("front", from: body),
              let back = extractTag("back", from: body) else { return nil }
        return .flashcard(.init(front: front, back: back))
    }

    /// `<quiz type="occlusion"><image>url</image><mask x="10" y="20" w="50" h="30" label="Heart"/></quiz>`
    private static func parseOcclusion(_ body: String) -> QuizContent? {
        guard let imageURL = extractTag("image", from: body) else { return nil }

        let ns = body as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // swiftlint:disable:next force_try
        let maskPattern = try! NSRegularExpression(
            pattern: #"<mask\s+x="([^"]+)"\s+y="([^"]+)"\s+w="([^"]+)"\s+h="([^"]+)"(?:\s+label="([^"]*)")?\s*/>"#
        )

        var masks: [[String: Double]] = []
        var labels: [String] = []

        maskPattern.enumerateMatches(in: body, range: fullRange) { match, _, _ in
            guard let match else { return }
            let x = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let y = Double(ns.substring(with: match.range(at: 2))) ?? 0
            let w = Double(ns.substring(with: match.range(at: 3))) ?? 0
            let h = Double(ns.substring(with: match.range(at: 4))) ?? 0
            masks.append(["x": x, "y": y, "w": w, "h": h])
            let label = match.range(at: 5).location != NSNotFound ? ns.substring(with: match.range(at: 5)) : ""
            labels.append(label)
        }

        return .occlusion(.init(imageURL: imageURL, masks: masks, labels: labels))
    }

    /// ```
    /// <quiz type="matching">
    ///   <pair><left>O2</left><right>Oxygen</right></pair>
    /// </quiz>
    /// ```
    private static func parseMatching(_ body: String) -> QuizContent? {
        let ns = body as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // swiftlint:disable:next force_try
        let pairPattern = try! NSRegularExpression(
            pattern: #"<pair>\s*<left>(.*?)</left>\s*<right>(.*?)</right>\s*</pair>"#,
            options: [.dotMatchesLineSeparators]
        )

        var pairs: [QuizContent.MatchingContent.Pair] = []
        pairPattern.enumerateMatches(in: body, range: fullRange) { match, _, _ in
            guard let match else { return }
            let left = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            pairs.append(.init(left: left, right: right))
        }

        guard !pairs.isEmpty else { return nil }
        return .matching(.init(pairs: pairs))
    }

    /// ```
    /// <quiz type="ordering">
    ///   <prompt>Order these by size</prompt>
    ///   <item>Atom</item>
    ///   <item>Cell</item>
    ///   <item>Organ</item>
    /// </quiz>
    /// ```
    private static func parseOrdering(_ body: String) -> QuizContent? {
        guard let prompt = extractTag("prompt", from: body) else { return nil }

        let ns = body as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // swiftlint:disable:next force_try
        let itemPattern = try! NSRegularExpression(
            pattern: #"<item>(.*?)</item>"#,
            options: [.dotMatchesLineSeparators]
        )

        var items: [String] = []
        itemPattern.enumerateMatches(in: body, range: fullRange) { match, _, _ in
            guard let match else { return }
            let value = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(value)
        }

        guard items.count >= 2 else { return nil }
        return .ordering(.init(prompt: prompt, items: items))
    }

    // MARK: - Helpers

    /// Extract the text content of an XML tag like `<tag>content</tag>`.
    private static func extractTag(_ tag: String, from body: String) -> String? {
        let ns = body as NSString
        let pattern = "<\(tag)>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
