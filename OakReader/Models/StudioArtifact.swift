import Foundation

// MARK: - Studio Artifact Kind

/// The kind of artifact generated from a document's content. Only `quiz` remains
/// (the concept-map / deck / audio kinds were removed — quiz cards were the one
/// genuinely useful artifact). Kept as an enum so the store's `kind` column and
/// the existing per-kind plumbing stay intact.
enum StudioArtifactKind: String, Codable, CaseIterable, Identifiable {
    case quiz

    var id: String { rawValue }
    var label: String { "Quiz" }
    var systemImage: String { "rectangle.on.rectangle.angled" }
    /// A one-line description shown on the generator tile.
    var blurb: String { "Flashcards to test recall" }
    var isAvailable: Bool { true }
}

// MARK: - Generation Parameters

/// Knobs surfaced in the customization sheet, NotebookLM-style. Persisted with
/// the artifact so a regeneration can reuse them.
struct StudioGenerationParams: Codable, Hashable {
    enum Difficulty: String, Codable, CaseIterable, Identifiable {
        case recall, understand, apply
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recall: return "Recall"
            case .understand: return "Understand"
            case .apply: return "Apply"
            }
        }
        /// A phrase fed to the generator prompt describing the cognitive level.
        var promptPhrase: String {
            switch self {
            case .recall: return "basic recall of key terms, names, dates, and definitions"
            case .understand: return "understanding of concepts and how they relate"
            case .apply: return "application and synthesis — apply ideas to new situations"
            }
        }
    }

    enum Amount: String, Codable, CaseIterable, Identifiable {
        case fewer, standard, more
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fewer: return "Fewer"
            case .standard: return "Standard"
            case .more: return "More"
            }
        }
        /// Approximate target count fed to the generator prompt.
        var count: Int {
            switch self {
            case .fewer: return 5
            case .standard: return 10
            case .more: return 20
            }
        }
    }

    /// An inclusive, 1-based span of PDF pages to scope generation to. `nil` (the
    /// default) means the whole document. Only meaningful for paginated sources.
    struct PageRange: Codable, Hashable {
        var start: Int
        var end: Int
        /// Clamped to `[1, max]` with `start ≤ end`.
        func clamped(to max: Int) -> PageRange {
            let hi = Swift.max(1, max)
            let lo = Swift.min(Swift.max(1, start), hi)
            let up = Swift.min(Swift.max(1, end), hi)
            return PageRange(start: Swift.min(lo, up), end: Swift.max(lo, up))
        }
    }

    var difficulty: Difficulty = .understand
    var amount: Amount = .standard
    var customPrompt: String = ""
    /// Page scoping for PDFs; `nil` = whole document.
    var pageRange: PageRange?

    static let `default` = StudioGenerationParams()
}

// MARK: - Studio Artifact

/// A generated, source-grounded quiz scoped to one library item. `body` is a JSON
/// deck: `{ "title": ..., "cards": [{type,data}, …] }` (see `QuizCardCodec`).
struct StudioArtifact: Identifiable, Hashable {
    let id: String
    let itemId: String
    let kind: StudioArtifactKind
    var title: String
    /// The artifact payload, format depending on `kind`:
    /// - `.quiz`: a JSON deck (`QuizCardCodec`).
    var body: String
    var params: StudioGenerationParams
    /// Relative path under the studio assets directory (audio only).
    var assetPath: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        itemId: String,
        kind: StudioArtifactKind,
        title: String,
        body: String,
        params: StudioGenerationParams = .default,
        assetPath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.itemId = itemId
        self.kind = kind
        self.title = title
        self.body = body
        self.params = params
        self.assetPath = assetPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decode a `.quiz` artifact's `body` into a renderable deck.
    var quizDeck: QuizDeck? {
        guard kind == .quiz else { return nil }
        return QuizCardCodec.deck(fromJSON: body)
    }
}
