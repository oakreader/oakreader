import Foundation
import GRDB

@Observable
class NotesViewModel {
    weak var parent: DocumentViewModel?

    // MARK: - State

    var notes: [Note] = []
    var selectedNoteId: UUID?
    var editorContent: String = ""
    var errorMessage: String?

    /// The currently selected note object (derived).
    var selectedNote: Note? {
        guard let id = selectedNoteId else { return nil }
        return notes.first { $0.id == id }
    }

    // MARK: - Private

    private let noteService: NoteService?
    private let storageKey: String?
    private var documentId: String?
    private var saveTask: Task<Void, Never>?
    private var lastSavedContent: String = ""

    // MARK: - Init

    init(parent: DocumentViewModel, database: CatalogDatabase?, storageKey: String?) {
        self.parent = parent
        self.storageKey = storageKey
        if let database {
            self.noteService = NoteService(database: database)
        } else {
            self.noteService = nil
        }
        resolveDocumentId()
        loadNotes()
    }

    /// Resolve the library document UUID from the storage key.
    private func resolveDocumentId() {
        guard let storageKey, let noteService else { return }
        documentId = try? noteService.database.dbQueue.read { db in
            try DocumentRecord
                .filter(DocumentRecord.CodingKeys.storageKey == storageKey)
                .fetchOne(db)?.id
        }
    }

    // MARK: - Load

    func loadNotes() {
        guard let documentId, let noteService else {
            notes = []
            return
        }
        do {
            notes = try noteService.fetchNotes(forDocumentId: documentId)
        } catch {
            Log.error(Log.store, "Failed to load notes: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Create

    func createNote() {
        guard let documentId, let storageKey, let noteService else { return }
        do {
            let note = try noteService.createNote(documentId: documentId, storageKey: storageKey)
            notes.insert(note, at: 0)
            selectNote(note)
        } catch {
            Log.error(Log.store, "Failed to create note: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Select / Deselect

    func selectNote(_ note: Note) {
        saveCurrentNoteIfNeeded()

        selectedNoteId = note.id
        // Load content from .md file
        if let storageKey, let noteService {
            editorContent = noteService.loadContent(noteId: note.id, storageKey: storageKey)
        } else {
            editorContent = ""
        }
        lastSavedContent = editorContent
    }

    func deselectNote() {
        saveCurrentNoteIfNeeded()
        selectedNoteId = nil
        editorContent = ""
        lastSavedContent = ""
    }

    // MARK: - Auto-Save (debounced)

    /// Called whenever the editor content changes (from the binding).
    func editorContentDidChange(_ newContent: String) {
        editorContent = newContent
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveCurrentNoteIfNeeded()
        }
    }

    private func saveCurrentNoteIfNeeded() {
        guard let noteId = selectedNoteId,
              let storageKey,
              let noteService,
              editorContent != lastSavedContent else { return }

        let content = editorContent
        let title = Self.extractTitle(from: content)

        do {
            try noteService.saveContent(
                noteId: noteId,
                storageKey: storageKey,
                title: title,
                content: content
            )
            lastSavedContent = content

            // Update the note in the local array
            if let idx = notes.firstIndex(where: { $0.id == noteId }) {
                notes[idx].title = title
                notes[idx].updatedAt = Date()
            }
        } catch {
            Log.error(Log.store, "Failed to save note: \(error)")
        }
    }

    private static func extractTitle(from content: String) -> String {
        let firstLine = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) ?? ""
        return String(firstLine.prefix(100))
    }

    // MARK: - Delete

    func deleteNote(_ note: Note) {
        guard let storageKey, let noteService else { return }
        do {
            try noteService.deleteNote(id: note.id, storageKey: storageKey)
            notes.removeAll { $0.id == note.id }
            if selectedNoteId == note.id {
                selectedNoteId = nil
                editorContent = ""
                lastSavedContent = ""
            }
        } catch {
            Log.error(Log.store, "Failed to delete note: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pin/Unpin

    func togglePin(_ note: Note) {
        guard let noteService else { return }
        let newValue = !note.isPinned
        do {
            try noteService.togglePin(id: note.id, isPinned: newValue)
            if let idx = notes.firstIndex(where: { $0.id == note.id }) {
                notes[idx].isPinned = newValue
                notes[idx].updatedAt = Date()
            }
            // Re-sort: pinned first, then by date
            notes.sort { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                return a.updatedAt > b.updatedAt
            }
        } catch {
            Log.error(Log.store, "Failed to toggle pin: \(error)")
        }
    }

    // MARK: - Image attachment

    /// Save image data and return the relative markdown path.
    func saveImage(_ data: Data, fileExtension: String = "png") -> String? {
        guard let storageKey, let noteService else { return nil }
        return try? noteService.saveImage(data: data, storageKey: storageKey, fileExtension: fileExtension)
    }

    /// Absolute URL of the notes directory (for WKWebView base URL).
    var notesDirectoryURL: URL? {
        guard let storageKey, let noteService else { return nil }
        return noteService.notesDirectoryURL(storageKey: storageKey)
    }

    // MARK: - Grouped Notes (for list display)

    /// Notes grouped by month for the Apple Notes-style section headers.
    var groupedNotes: [(key: String, notes: [Note])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"

        let pinned = notes.filter { $0.isPinned }
        let unpinned = notes.filter { !$0.isPinned }

        var groups: [(key: String, notes: [Note])] = []
        if !pinned.isEmpty {
            groups.append((key: "Pinned", notes: pinned))
        }

        let grouped = Dictionary(grouping: unpinned) { note in
            formatter.string(from: note.updatedAt)
        }
        let sortedKeys = grouped.keys.sorted { a, b in
            let dateA = grouped[a]?.first?.updatedAt ?? .distantPast
            let dateB = grouped[b]?.first?.updatedAt ?? .distantPast
            return dateA > dateB
        }
        for key in sortedKeys {
            if let items = grouped[key] {
                groups.append((key: key, notes: items))
            }
        }
        return groups
    }
}
