import AppKit

// MARK: - Command Category

enum CommandCategory: String, CaseIterable {
    case navigation = "Navigation"
    case view = "View"
    case file = "File"
    case settings = "Settings"
    case search = "Search"
    case theme = "Theme"
}

// MARK: - Command Context

/// Describes when a command should be visible/available.
struct CommandContext: OptionSet {
    let rawValue: Int

    static let always       = CommandContext(rawValue: 1 << 0)
    static let library      = CommandContext(rawValue: 1 << 1)
    static let pdf          = CommandContext(rawValue: 1 << 2)
    static let html         = CommandContext(rawValue: 1 << 3)
    static let markdown     = CommandContext(rawValue: 1 << 4)
    static let media        = CommandContext(rawValue: 1 << 5)

    /// Visible in any document type.
    static let anyDocument: CommandContext = [.pdf, .html, .markdown, .media]
}

// MARK: - Palette Action

/// The action a command executes when selected.
enum PaletteAction {
    /// Dispatch an existing DocumentAction through AppState.
    case documentAction(DocumentAction)
    /// Call an @objc selector on AppDelegate.
    case selector(Selector)
    /// Navigate to a specific settings tab.
    case settingsTab(String)
    /// Change appearance mode.
    case appearanceMode(String)
    /// Rebuild the full-text search index.
    case rebuildSearchIndex
}

// MARK: - Palette Command

/// A titled group of commands, rendered under a monospace section header.
/// Mirrors GatherOS's QuickSwitcher grouping (Collections / Tags / Saves).
struct PaletteSection {
    let title: String
    let commands: [PaletteCommand]
}

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let category: CommandCategory
    let icon: String
    let shortcut: String
    let context: CommandContext
    let action: PaletteAction

    init(
        id: String,
        title: String,
        category: CommandCategory,
        icon: String,
        shortcut: String = "",
        context: CommandContext = .always,
        action: PaletteAction
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.icon = icon
        self.shortcut = shortcut
        self.context = context
        self.action = action
    }
}
