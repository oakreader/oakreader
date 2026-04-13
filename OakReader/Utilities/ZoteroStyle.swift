import SwiftUI

enum ZoteroStyle {
    // MARK: - Colors

    enum Colors {
        static let tabBarBackground = Color(hex: "F2F2F2")
        static let sidebarBackground = Color(hex: "F2F2F2")
        static let activeTabBackground = Color(nsColor: .controlBackgroundColor)
        static let hoverBackground = Color.black.opacity(0.05)
        static let activeBackground = Color.black.opacity(0.10)
        static let divider = Color(hex: "DADADA")
    }

    // MARK: - Sizes

    enum Size {
        static let buttonStandard: CGFloat = 28
        static let toolbarHeight: CGFloat = 44
        static let tabHeight: CGFloat = 38
        static let tabBarHeight: CGFloat = 42  // topPad(4) + tabHeight(38)
        static let closeButton: CGFloat = 18
        static let sidenavWidth: CGFloat = 37
        static let rightPanelWidth: CGFloat = 520
        static let sidebarMin: CGFloat = 200
        static let sidebarMax: CGFloat = 320
        static let tabMin: CGFloat = 100
        static let tabMax: CGFloat = 200
    }

    // MARK: - Typography

    enum Font {
        /// Primary text size used in tabs, toolbar controls, page input
        static let body: CGFloat = 13
        /// Secondary text for labels, search results, popover controls
        static let caption: CGFloat = 12
        /// Toolbar and tab bar icon size
        static let icon: CGFloat = 14
        /// Small icon size (close buttons, chevrons in search)
        static let iconSmall: CGFloat = 11
    }

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }

    // MARK: - Radius

    enum Radius {
        static let standard: CGFloat = 8
        static let small: CGFloat = 3
        static let concave: CGFloat = 10
    }

    // MARK: - Annotation Colors (Zotero palette)

    enum AnnotationColors {
        static let yellow = Color(hex: "ffd400")
        static let red = Color(hex: "ff6666")
        static let green = Color(hex: "5fb236")
        static let blue = Color(hex: "2ea8e5")
        static let purple = Color(hex: "a28ae5")
        static let magenta = Color(hex: "e56eee")
        static let orange = Color(hex: "f19837")
        static let gray = Color(hex: "aaaaaa")
        static let black = Color(hex: "000000")

        static let allColors: [(name: String, color: Color, nsColor: NSColor)] = [
            ("Yellow", yellow, NSColor(red: 1.0, green: 0.831, blue: 0.0, alpha: 1.0)),
            ("Red", red, NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)),
            ("Green", green, NSColor(red: 0.373, green: 0.698, blue: 0.212, alpha: 1.0)),
            ("Blue", blue, NSColor(red: 0.180, green: 0.659, blue: 0.898, alpha: 1.0)),
            ("Purple", purple, NSColor(red: 0.635, green: 0.541, blue: 0.898, alpha: 1.0)),
            ("Magenta", magenta, NSColor(red: 0.898, green: 0.431, blue: 0.933, alpha: 1.0)),
            ("Orange", orange, NSColor(red: 0.945, green: 0.596, blue: 0.216, alpha: 1.0)),
            ("Gray", gray, NSColor(red: 0.667, green: 0.667, blue: 0.667, alpha: 1.0)),
            ("Black", black, NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)),
        ]
    }
}
