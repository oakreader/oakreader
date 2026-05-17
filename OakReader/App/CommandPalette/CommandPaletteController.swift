import AppKit

final class CommandPaletteController: NSObject, CommandPalettePanelDelegate {
    private lazy var panel: CommandPalettePanel = {
        let p = CommandPalettePanel()
        p.paletteDelegate = self
        return p
    }()

    private weak var appDelegate: AppDelegate?
    private var filteredCommands: [PaletteCommand] = []

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    // MARK: - Present / Dismiss

    func show() {
        guard let window = appDelegate?.appState.window else { return }

        if panel.isVisible {
            panel.dismiss()
            return
        }

        filteredCommands = availableCommands()
        panel.updateRows(filteredCommands)
        panel.present(relativeTo: window)
    }

    // MARK: - Context

    private func currentContext() -> CommandContext {
        guard let appDelegate else { return .always }
        let appState = appDelegate.appState

        guard let tab = appState.activeTab else {
            return [.always, .library]
        }

        switch tab.content {
        case .pdf:      return [.always, .pdf]
        case .html:     return [.always, .html]
        case .markdown: return [.always, .markdown]
        case .media:    return [.always, .media]
        }
    }

    private func availableCommands() -> [PaletteCommand] {
        let ctx = currentContext()
        return CommandRegistry.commands.filter { cmd in
            if cmd.context == .always { return true }
            return !cmd.context.intersection(ctx).isEmpty
        }
    }

    // MARK: - Fuzzy Search

    private func score(command: PaletteCommand, query: String) -> Int {
        let title = command.title.lowercased()
        let category = command.category.rawValue.lowercased()
        let q = query.lowercased()

        // Exact prefix match on title
        if title.hasPrefix(q) { return 100 }

        // Word-start match (e.g., "zf" matches "Zoom to Fit")
        let words = title.split(separator: " ").map { String($0) }
        let wordStarts = String(words.compactMap(\.first))
        if wordStarts.lowercased().hasPrefix(q) { return 90 }

        // Substring match on title
        if title.contains(q) { return 70 }

        // Category match
        if category.contains(q) { return 50 }

        // Subsequence match on title
        if isSubsequence(q, of: title) { return 30 }

        return 0
    }

    private func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var haystackIndex = haystack.startIndex
        for char in needle {
            guard let found = haystack[haystackIndex...].firstIndex(of: char) else {
                return false
            }
            haystackIndex = haystack.index(after: found)
        }
        return true
    }

    // MARK: - CommandPalettePanelDelegate

    func commandPaletteSearchChanged(_ panel: CommandPalettePanel, text: String) {
        let term = text.trimmingCharacters(in: .whitespaces)
        let available = availableCommands()

        if term.isEmpty {
            filteredCommands = available
        } else {
            filteredCommands = available
                .map { (cmd: $0, score: score(command: $0, query: term)) }
                .filter { $0.score > 0 }
                .sorted { $0.score > $1.score }
                .map(\.cmd)
        }

        panel.updateRows(filteredCommands)
    }

    func commandPaletteDidActivate(_ panel: CommandPalettePanel, at index: Int) {
        guard index >= 0, index < filteredCommands.count else { return }
        panel.dismiss()
        execute(filteredCommands[index])
    }

    func commandPaletteDidDismiss(_ panel: CommandPalettePanel) {
        // No cleanup needed
    }

    // MARK: - Execution

    private func execute(_ command: PaletteCommand) {
        guard let appDelegate else { return }

        switch command.action {
        case .documentAction(let action):
            appDelegate.appState.dispatchAction(action)
            NotificationCenter.default.post(name: .documentAction, object: action)

        case .selector(let selector):
            appDelegate.perform(selector, with: nil)

        case .settingsTab(let tabId):
            NotificationCenter.default.post(
                name: .settingsNavigateToTab,
                object: nil,
                userInfo: ["tab": tabId]
            )
            appDelegate.showSettingsWindow(nil)

        case .appearanceMode(let mode):
            Preferences.shared.appearanceMode = mode

        case .rebuildSemanticIndex:
            NotificationCenter.default.post(name: .semanticIndexRebuildRequested, object: nil)
        }
    }
}
