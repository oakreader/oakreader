import AppKit

// Stand-ins for app types the note editor references but the harness does not test.
struct NoteRef: Identifiable, Hashable {
    let id: String
    let preview: String
    let time: String
}

struct ChatCompletionItem {
    let id: String
    let icon: String
    let label: String
    let section: String
    let trigger: String
    static func note(id: String, icon: String, label: String, description: String = "", section: String,
                     trigger: String, pinnedDescription: Bool = false) -> ChatCompletionItem {
        ChatCompletionItem(id: id, icon: icon, label: label, section: section, trigger: trigger)
    }
}

final class ChatCompletionPanel: NSPanel {
    var items: [ChatCompletionItem]
    var selectedItem: ChatCompletionItem? { items.first }
    init(items: [ChatCompletionItem], anchorRect: NSRect, screenVisibleFrame: NSRect,
         onSelect: @escaping (ChatCompletionItem) -> Void) {
        self.items = items
        super.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    }
    func dismiss() {}
    func moveSelection(by: Int) {}
    func filter(query: String) {}
}

enum NoteLink {
    static func href(_ id: String) -> String { "oak://note/\(id)" }
    static func id(from url: URL) -> String? {
        guard url.scheme == "oak", url.host == "note" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }
}
