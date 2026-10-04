import Foundation

/// Text conditioning Pocket TTS expects before a prompt reaches the model.
///
/// These rules are not cosmetic. The model was trained on sentence-shaped input, so a lowercase
/// fragment with no terminal punctuation generates noticeably worse prosody, and a very short
/// prompt tends to be cut off before the word is spoken. Kyutai's reference applies all of them
/// inside `generate_audio`; we apply them here so the engine stays a straight model driver.
///
/// Mirrors the reference behaviour in `kyutai-labs/pocket-tts` (MIT) and its Swift restatement
/// in `Blaizzy/mlx-audio-swift` (MIT).
enum PocketTTSTextPreparation {
    /// Per-chunk token budget. Kyutai's `MAX_TOKEN_PER_CHUNK`.
    ///
    /// Well under the model's 128-token hard limit on purpose: autoregressive error compounds
    /// across a chunk, so packing fewer tokens gives better prosody on long passages.
    static let maxTokensPerChunk = 50

    /// Condition one chunk and report how many frames to run past end-of-speech.
    ///
    /// Short prompts get more trailing frames because their final word is likelier to be
    /// clipped by an early end-of-speech.
    static func prepare(_ text: String) -> (text: String, framesAfterEOSGuess: Int) {
        var prepared = text.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared = prepared
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        while prepared.contains("  ") {
            prepared = prepared.replacingOccurrences(of: "  ", with: " ")
        }

        let wordCount = prepared.split(separator: " ").count
        let framesAfterEOSGuess = wordCount <= 4 ? 3 : 1

        if let first = prepared.first, !first.isUppercase {
            prepared = first.uppercased() + prepared.dropFirst()
        }
        // A trailing letter or digit reads as a cut-off fragment to the model.
        if let last = prepared.last, last.isLetter || last.isNumber {
            prepared += "."
        }
        // Pad very short prompts so the model has some run-up before the first word.
        if prepared.split(separator: " ").count < 5 {
            prepared = String(repeating: " ", count: 8) + prepared
        }
        return (prepared, framesAfterEOSGuess)
    }

    /// Split text into chunks that each stay within the token budget, preferring sentence ends.
    ///
    /// Sentence boundaries are found in token space rather than with string matching, so
    /// abbreviations that tokenize as one piece do not split a sentence in half. A single
    /// sentence longer than the budget is emitted whole: cutting mid-sentence sounds worse than
    /// the extra drift, and the engine's generation cap still bounds it.
    static func splitIntoChunks(_ text: String, tokenizer: PocketTTSTokenizer) -> [String] {
        let prepared = prepare(text).text.trimmingCharacters(in: .whitespaces)
        guard !prepared.isEmpty else { return [] }

        let tokens = tokenizer.encode(prepared)
        guard !tokens.isEmpty else { return [prepared] }

        // Pieces that close a sentence. Taken as token ids so the comparison is exact.
        let terminators = Set(tokenizer.encode(".!?…"))

        // A sentence ends at the last terminator of a run of them, so "?!" stays together.
        var boundaries: [Int] = [0]
        var previousWasTerminator = false
        for (index, token) in tokens.enumerated() {
            if terminators.contains(token) {
                previousWasTerminator = true
            } else {
                if previousWasTerminator { boundaries.append(index) }
                previousWasTerminator = false
            }
        }
        boundaries.append(tokens.count)

        // One entry per sentence, carrying its token count so chunks can be packed by budget.
        var sentences: [(tokenCount: Int, text: String)] = []
        for i in 0..<(boundaries.count - 1) {
            let range = boundaries[i]..<boundaries[i + 1]
            guard !range.isEmpty else { continue }
            let decoded = tokenizer.decode(Array(tokens[range])).trimmingCharacters(in: .whitespaces)
            guard !decoded.isEmpty else { continue }
            sentences.append((range.count, decoded))
        }
        guard !sentences.isEmpty else { return [prepared] }

        // Greedily pack whole sentences up to the budget.
        var chunks: [String] = []
        var current = ""
        var currentTokens = 0
        for sentence in sentences {
            if !current.isEmpty, currentTokens + sentence.tokenCount > maxTokensPerChunk {
                chunks.append(current)
                current = sentence.text
                currentTokens = sentence.tokenCount
            } else {
                current = current.isEmpty ? sentence.text : current + " " + sentence.text
                currentTokens += sentence.tokenCount
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
