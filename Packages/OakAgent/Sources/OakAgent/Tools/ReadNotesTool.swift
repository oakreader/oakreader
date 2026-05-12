import Foundation

/// Reads notes associated with a document.
/// Takes a `notesDirectory` URL at init to avoid app-layer dependencies.
/// Notes are stored as `{id}.md` files in the notes directory.
public struct ReadNotesTool: AgentTool, Sendable {
    public let name = "read_notes"
    public let description = """
        Read notes for the current document. Call without arguments to list all notes, \
        or specify a note title to read its full content.
        """
    public let notes: [(id: String, title: String)]
    public let notesDirectory: URL

    public init(notes: [(id: String, title: String)], notesDirectory: URL) {
        self.notes = notes
        self.notesDirectory = notesDirectory
    }

    public var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Title of the note to read. Omit to list all notes."
                ]
            ]
        ]
    }

    public func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard !notes.isEmpty else {
            return .success("No notes found for this document.")
        }

        if let title = input["title"], !title.isEmpty {
            return readNote(title: title)
        } else {
            return listNotes()
        }
    }

    private func listNotes() -> ToolOutput {
        let list = notes.enumerated().map { (i, note) in
            "\(i + 1). \(note.title.isEmpty ? "(Untitled)" : note.title)"
        }.joined(separator: "\n")
        return .success("Notes for this document:\n\(list)")
    }

    private func readNote(title: String) -> ToolOutput {
        let titleLower = title.lowercased()
        guard let match = notes.first(where: { $0.title.lowercased() == titleLower })
                ?? notes.first(where: { $0.title.lowercased().contains(titleLower) }) else {
            let available = notes.map {
                $0.title.isEmpty ? "(Untitled)" : $0.title
            }.joined(separator: ", ")
            return .error("Note \"\(title)\" not found. Available notes: \(available)")
        }

        guard let noteId = UUID(uuidString: match.id) else {
            return .error("Invalid note ID")
        }

        let url = notesDirectory.appendingPathComponent("\(noteId.uuidString).md")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .error("Failed to read note content from disk")
        }

        if content.isEmpty {
            return .success("Note \"\(match.title)\" is empty.")
        }
        return .success("Note: \(match.title)\n\n\(String(content.prefix(30_000)))")
    }
}
