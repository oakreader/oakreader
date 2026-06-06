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
    case annotations
    case search

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .outline: return "Outline"
        case .annotations: return "Annotations"
        case .search: return "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .thumbnails: return "rectangle.grid.2x2"
        case .outline: return "list.number"
        case .annotations: return "text.bubble"
        case .search: return "magnifyingglass"
        }
    }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case none
    case highlight
    case underline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Select"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "cursor.rays"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        }
    }
}

enum FormFieldType: String, CaseIterable, Identifiable {
    case textField
    case checkbox
    case radioButton
    case dropdown
    case pushButton
    case signature

    var id: String { rawValue }

    var label: String {
        switch self {
        case .textField: return "Text Field"
        case .checkbox: return "Checkbox"
        case .radioButton: return "Radio Button"
        case .dropdown: return "Dropdown"
        case .pushButton: return "Button"
        case .signature: return "Signature"
        }
    }

    var systemImage: String {
        switch self {
        case .textField: return "character.cursor.ibeam"
        case .checkbox: return "checkmark.square"
        case .radioButton: return "circle.inset.filled"
        case .dropdown: return "chevron.down.square"
        case .pushButton: return "button.horizontal.top.press"
        case .signature: return "signature"
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
    case aiChat
    case metadata
    case translation
    case quizCards = "flashcards"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .metadata: return "list.bullet.rectangle.portrait"
        case .aiChat: return "bubble.left.and.bubble.right"
        case .translation: return "translate"
        case .quizCards: return "rectangle.on.rectangle.angled"
        }
    }

    var label: String {
        switch self {
        case .metadata: return "Metadata"
        case .aiChat: return "AI Chat"
        case .translation: return "Translation"
        case .quizCards: return "Quiz Cards"
        }
    }
}

enum AppExtension: String, CaseIterable, Identifiable {
    case translation
    case quizCards = "flashcards"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .translation: return "Translation"
        case .quizCards: return "Quiz Cards"
        }
    }

    var description: String {
        switch self {
        case .translation: return "Translate selected text using AI-powered translation."
        case .quizCards: return "Spaced repetition quiz cards with FSRS scheduling."
        }
    }

    /// SF Symbol name.
    var systemImage: String {
        switch self {
        case .translation: return "translate"
        case .quizCards: return "rectangle.on.rectangle.angled"
        }
    }

    /// Custom asset catalog image name. Non-nil means use `Image(_:)` instead of SF Symbol.
    var iconAsset: String? {
        nil
    }

    var rightPanelModes: [RightPanelMode] {
        switch self {
        case .translation: return [.translation]
        case .quizCards: return [.quizCards]
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
    case chat
    case metadata
    case quizCards

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .metadata: return "list.bullet.rectangle.portrait"
        case .quizCards: return "rectangle.on.rectangle.angled"
        }
    }

    var label: String {
        switch self {
        case .chat: return "AI Chat"
        case .metadata: return "Metadata"
        case .quizCards: return "Quiz Cards"
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
    static let pageWidth: CGFloat = 612  // US Letter
    static let pageHeight: CGFloat = 792
    static let defaultPageSize = CGSize(width: pageWidth, height: pageHeight)
    static let defaultMargin: CGFloat = 36 // 0.5 inch
    static let thumbnailSize = CGSize(width: 110, height: 142)
    static let highlightColor = NSColor.yellow.withAlphaComponent(0.5)
    static let watermarkOpacity: CGFloat = 0.3
    static let watermarkFontSize: CGFloat = 72
    static let batesNumberFormat = "%06d"
    static let searchHighlightColor = NSColor.systemYellow.withAlphaComponent(0.4)
    static let annotationDefaultColor = NSColor.systemRed
    static let annotationDefaultLineWidth: CGFloat = 1.5
    static let defaultFontName = "Helvetica"
    static let defaultFontSize: CGFloat = 12.0
}
