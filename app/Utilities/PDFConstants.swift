import AppKit
import PDFKit

enum EditorMode: String, CaseIterable, Identifiable {
    case viewer
    case annotate
    case snapshot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .viewer: return "View"
        case .annotate: return "Annotate"
        case .snapshot: return "Snapshot"
        }
    }

    var systemImage: String {
        switch self {
        case .viewer: return "eye"
        case .annotate: return "highlighter"
        case .snapshot: return "crop"
        }
    }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case thumbnails
    case outline
    case search

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .outline: return "Outline"
        case .search: return "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .thumbnails: return "rectangle.grid.2x2"
        case .outline: return "list.number"
        case .search: return "magnifyingglass"
        }
    }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case none
    case highlight
    case underline
    case strikethrough

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Select"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "cursor.rays"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        }
    }
}

enum LibrarySidebarMode: String, CaseIterable, Identifiable {
    case collections
    case tags

    var id: String { rawValue }

    var label: String {
        switch self {
        case .collections: return "Collections"
        case .tags: return "Tags"
        }
    }

    var systemImage: String {
        switch self {
        case .collections: return "folder"
        case .tags: return "tag"
        }
    }
}

enum RightPanelMode: String, CaseIterable, Identifiable {
    // Tab order in the document view (Notes after Translation, Metadata last).
    case aiChat
    case translation
    case comments
    case metadata

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .metadata: return "list.bullet.rectangle.portrait"
        case .aiChat: return "bubble.left.and.bubble.right"
        case .comments: return "note.text"
        case .translation: return "translate"
        }
    }

    var label: String {
        switch self {
        case .metadata: return "Metadata"
        case .aiChat: return "AI Chat"
        case .comments: return "Notes"
        case .translation: return "Translation"
        }
    }
}

enum AppExtension: String, CaseIterable, Identifiable {
    case translation
    case notes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .translation: return "Translation"
        case .notes: return "Notes"
        }
    }

    var description: String {
        switch self {
        case .translation: return "Translate selected text using AI-powered translation."
        case .notes: return "Capture highlights and notes in a side panel."
        }
    }

    /// SF Symbol name.
    var systemImage: String {
        switch self {
        case .translation: return "translate"
        case .notes: return "note.text"
        }
    }

    /// Custom asset catalog image name. Non-nil means use `Image(_:)` instead of SF Symbol.
    var iconAsset: String? {
        nil
    }

    var rightPanelModes: [RightPanelMode] {
        switch self {
        case .translation: return [.translation]
        case .notes: return [.comments]
        }
    }

    var systemCollectionId: UUID? {
        nil
    }

    var enabledByDefault: Bool {
        true
    }
}

enum MetadataInspectorTab: String, CaseIterable, Identifiable {
    case info
    case reference

    var id: String { rawValue }
    var label: String {
        switch self {
        case .info: return "Info"
        case .reference: return "Reference"
        }
    }
    var systemImage: String {
        switch self {
        case .info: return "info.circle"
        case .reference: return "text.book.closed"
        }
    }
}

enum LibraryDetailTab: String, CaseIterable, Identifiable {
    case metadata
    /// Chat scoped to the selected collection — the library's counterpart to a
    /// document tab's `RightPanelMode.aiChat`.
    case chat

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .metadata: return "list.bullet.rectangle.portrait"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }

    var label: String {
        switch self {
        case .metadata: return "Metadata"
        case .chat: return "Chat"
        }
    }
}

enum CompressionQuality: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case maximum

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low (Smallest File)"
        case .medium: return "Medium"
        case .high: return "High"
        case .maximum: return "Maximum (Best Quality)"
        }
    }

    var jpegQuality: CGFloat {
        switch self {
        case .low: return 0.3
        case .medium: return 0.5
        case .high: return 0.75
        case .maximum: return 0.9
        }
    }

    var maxDPI: Int {
        switch self {
        case .low: return 72
        case .medium: return 150
        case .high: return 225
        case .maximum: return 300
        }
    }
}

struct PDFDefaults {
    static let searchHighlightColor = NSColor.systemYellow.withAlphaComponent(0.4)
    // Yellow is the conventional highlight default (Preview, Acrobat, Zotero) and
    // is the first swatch in every color picker — keep the default in sync with it
    // rather than diverging to red.
    static let annotationDefaultColor =
        OakStyle.AnnotationColors.highlightColors.first?.nsColor ?? NSColor.systemYellow
    static let annotationDefaultLineWidth: CGFloat = 1.5
    static let defaultFontName = "Helvetica"
    static let defaultFontSize: CGFloat = 12.0
}
