import Foundation
import OakAgent

/// Read-only aggregation of every quiz card the AI generated for a single
/// document, gathered across ALL of the item's conversations.
///
/// Quiz cards have no separate store — they live in the chat history that
/// produced them, as `quiz_cards` tool calls on each turn. This view model is
/// just a per-item lens: it walks the item's conversations, loads their turns
/// from disk, and reconstructs the decks. Nothing is written; there is no
/// curation, editing, or export. (One item can have many chats, so cards are
/// grouped by the conversation that produced them.)
@Observable
final class ItemQuizCardsViewModel {
    weak var parent: DocumentViewModel?

    /// Decks produced within one conversation, newest conversation first.
    struct Section: Identifiable {
        let id: UUID
        let title: String
        let date: Date
        let decks: [QuizDeck]
    }

    var sections: [Section] = []
    var isLoaded = false

    var totalCards: Int {
        sections.reduce(0) { $0 + $1.decks.reduce(0) { $0 + $1.cards.count } }
    }

    init(parent: DocumentViewModel?) {
        self.parent = parent
    }

    /// Re-scan the item's chat history. Cheap for typical sizes (a handful of
    /// JSONL files) — the turn loader is actor-isolated, so we await each one.
    @MainActor
    func reload() async {
        guard let database = parent?.database, let itemId = parent?.itemId else {
            sections = []
            isLoaded = true
            return
        }

        let conversations = ConversationService(database: database)
        let store = SessionStore(baseDirectory: CatalogDatabase.chatsDirectory)
        let metas = (try? conversations.fetchSessions(forItemId: itemId)) ?? []

        var result: [Section] = []
        for meta in metas {
            let turns = (try? await store.loadTurns(sessionId: meta.id)) ?? []
            let decks: [QuizDeck] = turns.flatMap { turn in
                turn.toolUses
                    .filter { $0.name == "quiz_cards" }
                    .compactMap { QuizCardsTool.deck(from: $0) }
            }
            guard !decks.isEmpty else { continue }
            result.append(Section(id: meta.id, title: meta.title, date: meta.lastMessageAt, decks: decks))
        }
        sections = result
        isLoaded = true
    }
}
