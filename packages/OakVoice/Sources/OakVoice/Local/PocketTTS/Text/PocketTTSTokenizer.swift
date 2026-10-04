import Foundation

/// SentencePiece **Unigram** tokenizer for Kyutai's Pocket TTS.
///
/// Written rather than taken from a library because the model's `tokenizer.json` needs two
/// things together that no Swift package gave us: the Unigram Viterbi lattice *and*
/// `byte_fallback`. swift-transformers ships `UnigramTokenizer`, and it reproduces Kyutai's
/// token ids exactly, but it emits `<unk>` for any character outside the 4000-piece vocab.
/// For a reader that is fatal: `@`, `§`, parentheses and accented names are absent from the
/// vocab and appear constantly in PDFs and articles.
///
/// Pipeline, read off `tokenizer.json` (`normalizer`, `pre_tokenizer`, `model`):
///   1. Normalizer `Prepend "▁"` — glue a metaspace onto the front.
///   2. Pre-tokenizer `Metaspace(replacement: "▁", prepend_scheme: .always, split: true)` —
///      swap spaces for `▁`, then cut the string into segments that each keep their leading `▁`.
///   3. Per segment, Viterbi over the vocab maximising the sum of log-probabilities.
///   4. Any character no piece covers decomposes into its UTF-8 bytes as `<0xNN>` tokens.
///
/// Verified against the reference ids for "Hello world, this is a Core ML conversion test.":
/// `[2994, 578, 262, 285, 277, 267, 1221, 280, 657, 1171, 260, 1031, 261, 419, 1115, 263]`.
public struct PocketTTSTokenizer: Sendable {
    /// One vocabulary entry: the piece and its log-probability.
    private struct Piece: Sendable {
        let id: Int32
        let score: Float
    }

    /// Piece string → id + score. The vocab is 4000 entries, so a dictionary beats a trie here.
    private let pieces: [String: Piece]

    /// Id of `<0x00>`. The 256 byte tokens are contiguous, so byte `n` is `byteTokenBase + n`.
    private let byteTokenBase: Int32

    /// Score given to a character the vocab cannot represent. Low enough that Viterbi only
    /// takes this edge when nothing else covers the position.
    private let unknownScore: Float

    /// Longest piece in the vocab, in characters. Bounds the inner Viterbi loop.
    private let maxPieceLength: Int

    /// The metaspace marker SentencePiece substitutes for a space.
    private static let metaspace: Character = "\u{2581}"

    public enum TokenizerError: Error, CustomStringConvertible {
        case unreadable(URL, underlying: Error)
        case malformed(String)

        public var description: String {
            switch self {
            case let .unreadable(url, underlying):
                return "cannot read \(url.lastPathComponent): \(underlying)"
            case let .malformed(why):
                return "tokenizer.json is malformed — \(why)"
            }
        }
    }

    // MARK: - Loading

    /// Parse a HuggingFace `tokenizer.json` carrying a Unigram model.
    public init(tokenizerJSONURL url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TokenizerError.unreadable(url, underlying: error)
        }
        try self.init(tokenizerJSON: data)
    }

    public init(tokenizerJSON data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any]
        else { throw TokenizerError.malformed("no top-level \"model\" object") }

        guard (model["type"] as? String) == "Unigram" else {
            throw TokenizerError.malformed("model.type is \(model["type"] ?? "nil"), expected Unigram")
        }
        guard let vocab = model["vocab"] as? [[Any]] else {
            throw TokenizerError.malformed("model.vocab is not an array of [piece, score] pairs")
        }

        var table = [String: Piece](minimumCapacity: vocab.count)
        var longest = 1
        var byteBase: Int32?
        var lowest = Float.greatestFiniteMagnitude

        for (index, entry) in vocab.enumerated() {
            guard let piece = entry.first as? String else {
                throw TokenizerError.malformed("vocab[\(index)] has no piece string")
            }
            // Scores arrive as JSON numbers; 0.0 for the specials.
            let score = Float((entry.count > 1 ? entry[1] as? NSNumber : nil)?.doubleValue ?? 0)
            let id = Int32(index)

            // `<0x00>` anchors the contiguous run of 256 byte-fallback tokens.
            if piece == "<0x00>" { byteBase = id }

            // First writer wins: a duplicate piece later in the vocab has a lower score.
            if table[piece] == nil {
                table[piece] = Piece(id: id, score: score)
            }
            longest = max(longest, piece.count)
            if score < lowest { lowest = score }
        }

        guard let byteBase else {
            throw TokenizerError.malformed("vocab has no <0x00>, so byte_fallback is impossible")
        }

        self.pieces = table
        self.byteTokenBase = byteBase
        self.maxPieceLength = longest
        // SentencePiece's own convention: push unknown well below the worst real piece.
        self.unknownScore = lowest - 10
    }

    // MARK: - Encoding

    /// Encode `text` into Pocket TTS token ids.
    public func encode(_ text: String) -> [Int32] {
        // Steps 1 and 2: prepend a metaspace, swap spaces for metaspaces, then split so that
        // every segment keeps the metaspace that introduced it.
        let normalized = String(Self.metaspace) + text.replacingOccurrences(of: " ", with: String(Self.metaspace))

        var tokens: [Int32] = []
        var segment = ""
        for character in normalized {
            if character == Self.metaspace, !segment.isEmpty {
                tokens.append(contentsOf: encodeSegment(segment))
                segment = ""
            }
            segment.append(character)
        }
        if !segment.isEmpty {
            tokens.append(contentsOf: encodeSegment(segment))
        }
        return tokens
    }

    /// Viterbi over one metaspace-delimited segment.
    ///
    /// `best[i]` is the score of the best tokenization of the first `i` characters, and
    /// `backPointer[i]` records the piece that closed that path.
    private func encodeSegment(_ segment: String) -> [Int32] {
        let characters = Array(segment)
        let count = characters.count
        guard count > 0 else { return [] }

        /// How a path arrived at a position: a real vocab piece, or a character to byte-expand.
        enum Edge {
            case piece(Int32)
            case unknown(Character)
        }

        var best = [Float](repeating: -.greatestFiniteMagnitude, count: count + 1)
        var backPointer = [Edge?](repeating: nil, count: count + 1)
        var backLength = [Int](repeating: 0, count: count + 1)
        best[0] = 0

        for start in 0..<count where best[start] > -.greatestFiniteMagnitude {
            let limit = min(count, start + maxPieceLength)

            // Longest-to-shortest is not required for correctness; every length is tried.
            for end in (start + 1)...limit {
                let candidate = String(characters[start..<end])
                guard let piece = pieces[candidate] else { continue }
                let score = best[start] + piece.score
                if score > best[end] {
                    best[end] = score
                    backPointer[end] = .piece(piece.id)
                    backLength[end] = end - start
                }
            }

            // Byte-fallback edge: always available for a single character, so the lattice can
            // never dead-end on a glyph the vocab lacks.
            let end = start + 1
            let score = best[start] + unknownScore
            if score > best[end] {
                best[end] = score
                backPointer[end] = .unknown(characters[start])
                backLength[end] = 1
            }
        }

        // Walk the back-pointers from the end, then reverse.
        var reversed: [Int32] = []
        var position = count
        while position > 0, let edge = backPointer[position] {
            switch edge {
            case let .piece(id):
                reversed.append(id)
            case let .unknown(character):
                // UTF-8 bytes, appended in reverse because the whole list is reversed below.
                for byte in String(character).utf8.reversed() {
                    reversed.append(byteTokenBase + Int32(byte))
                }
            }
            position -= backLength[position]
        }
        return reversed.reversed()
    }

    // MARK: - Decoding

    /// Inverse of `encode`, for tests and logging. Byte tokens are reassembled into UTF-8.
    public func decode(_ tokens: [Int32]) -> String {
        // id → piece, built lazily per call; decode is not on the synthesis hot path.
        var byId = [Int32: String](minimumCapacity: pieces.count)
        for (piece, entry) in pieces { byId[entry.id] = piece }

        var bytes: [UInt8] = []
        for token in tokens {
            if token >= byteTokenBase, token < byteTokenBase + 256 {
                bytes.append(UInt8(token - byteTokenBase))
            } else if let piece = byId[token] {
                bytes.append(contentsOf: Array(piece.utf8))
            }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.replacingOccurrences(of: String(Self.metaspace), with: " ")
    }
}
