import Foundation

// MARK: - Studio Artifact Kind

/// The kind of artifact the AI Studio generates from a document's content.
/// Each kind has a one-shot generator and a renderer; see `StudioGenerator`.
enum StudioArtifactKind: String, Codable, CaseIterable, Identifiable {
    case quiz
    case mindmap
    case deck
    case audio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quiz: return "Quiz"
        case .mindmap: return "Mind Map"
        case .deck: return "Slide Deck"
        case .audio: return "Audio Overview"
        }
    }

    var systemImage: String {
        switch self {
        case .quiz: return "rectangle.on.rectangle.angled"
        case .mindmap: return "point.3.connected.trianglepath.dotted"
        case .deck: return "play.rectangle"
        case .audio: return "waveform"
        }
    }

    /// A one-line description shown on the generator tile.
    var blurb: String {
        switch self {
        case .quiz: return "Flashcards to test recall"
        case .mindmap: return "A visual concept tree"
        case .deck: return "Slides to present"
        case .audio: return "A narrated overview"
        }
    }

    /// Whether this kind is wired up yet. Tiles for unimplemented kinds render
    /// disabled. Deck / audio land in later phases.
    var isAvailable: Bool {
        switch self {
        case .quiz, .mindmap: return true
        case .deck, .audio: return false
        }
    }
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

    var difficulty: Difficulty = .understand
    var amount: Amount = .standard
    var customPrompt: String = ""

    static let `default` = StudioGenerationParams()
}

// MARK: - Studio Artifact

/// A generated, source-grounded artifact scoped to one library item.
///
/// `body` carries the renderable payload, by kind:
/// - `.quiz` — a JSON object `{ "title": ..., "cards": [{type,data}, …] }`
/// - `.mindmap` — a nested Markdown outline
/// - `.deck` — Marp Markdown
/// - `.audio` — the narration script (the synthesized file lives at `assetPath`)
struct StudioArtifact: Identifiable, Hashable {
    let id: String
    let itemId: String
    let kind: StudioArtifactKind
    var title: String
    /// The artifact payload, format depending on `kind`:
    /// - `.quiz`: a JSON deck (`QuizCardCodec`).
    /// - `.mindmap`: the streamed bullet outline, or a Mind Elixir JSON object
    ///   once the map has been hand-edited (so images / comments / math survive).
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
