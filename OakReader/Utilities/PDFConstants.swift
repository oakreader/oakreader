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
        case .thumbnails: return "rectangle.split.3x3"
        case .outline: return "list.bullet.indent"
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


enum RightPanelMode: String, CaseIterable, Identifiable {
    case aiChat
    case notes
    case inspector

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .inspector: return "info.circle"
        case .aiChat: return "bubble.left.and.bubble.right"
        case .notes: return "note.text"
        }
    }

    var label: String {
        switch self {
        case .inspector: return "Info"
        case .aiChat: return "AI Chat"
        case .notes: return "Notes"
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
