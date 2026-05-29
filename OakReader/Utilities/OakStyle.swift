import SwiftUI
import AppKit

// MARK: - Tab Active Environment

/// Whether the enclosing document tab is the currently active (visible) tab.
/// Set once in `RootView` via `.environment(\.isTabActive, …)` and read by any
/// descendant that manages global `NSEvent` monitors or other resources that
/// should only be active when the tab is on-screen.
private struct IsTabActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isTabActive: Bool {
        get { self[IsTabActiveKey.self] }
        set { self[IsTabActiveKey.self] = newValue }
    }
}

// MARK: - Font Family

enum FontFamily: String, CaseIterable, Identifiable {
    case system = "system"
    case serif = "serif"
    case sansSerif = "sans-serif"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .sansSerif: return "Sans-serif"
        }
    }

    /// SwiftUI `Font.Design` for use with `.system(size:weight:design:)`.
    var swiftUIDesign: Font.Design {
        switch self {
        case .system: return .default
        case .serif: return .serif
        case .sansSerif: return .default
        }
    }

    /// Concrete font name for `NSFont` contexts.
    var fontName: String {
        switch self {
        case .system: return ".AppleSystemUIFont"
        case .serif: return "New York"
        case .sansSerif: return ".AppleSystemUIFont"
        }
    }
}

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum OakStyle {
    // MARK: - Colors
    // Uses opacity-based tints for better light/dark mode adaptability.

    enum Colors {
        // Backgrounds (Dia gray scale: #F8F8F8 → #F2F2F2 → #EDEDED)
        static let tabBarBackground = Color(nsColor: .windowBackgroundColor)
        static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
        static let activeTabBackground = Color(nsColor: .textBackgroundColor)  // white — merges with content
        static let contentBackground = Color(nsColor: .textBackgroundColor)

        // Interactive states
        static let hoverBackground = Color.primary.opacity(0.06)
        static let activeBackground = Color.primary.opacity(0.10)
        static let selectedBackground = Color.accentColor.opacity(0.12)

        // Borders & dividers
        static let divider = Color.primary.opacity(0.08)
        static let border = Color.primary.opacity(0.10)
        static let borderSubtle = Color.primary.opacity(0.05)

        // Text
        static let textPrimary = Color.primary.opacity(1.0)
        static let textSecondary = Color.primary.opacity(0.60)
        static let textTertiary = Color.primary.opacity(0.35)
        static let textQuaternary = Color.primary.opacity(0.20)

        // Buttons (Dia-style)
        static let buttonBackground = Color.primary.opacity(0.07)
        static let buttonBackgroundHover = Color.primary.opacity(0.12)
        static let buttonForeground = Color.primary.opacity(0.80)

        // Dia chat-panel tokens (measured from Dia 1.32 — see dia-design-tokens).
        /// Panel surface — #FEFFFF light / #2D2D2D dark (a mid-gray, not near-black).
        static let diaSurface = Color(nsColor: NSColor(name: "DiaSurface") { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x2D / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xFE / 255.0, green: 0xFF / 255.0, blue: 0xFF / 255.0, alpha: 1)
        })
        /// Hairline border — #0F182C @8% light / #787D86 @32% dark.
        static let diaHairline = Color(nsColor: NSColor(name: "DiaHairline") { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x78 / 255.0, green: 0x7D / 255.0, blue: 0x86 / 255.0, alpha: 0.32)
                : NSColor(srgbRed: 0x0F / 255.0, green: 0x18 / 255.0, blue: 0x2C / 255.0, alpha: 0.08)
        })
    }

    // MARK: - Sizes

    enum Size {
        static let buttonStandard: CGFloat = 28
        static let tabHeight: CGFloat = 40
        static let tabBarHeight: CGFloat = 40
        static let closeButton: CGFloat = 18
        static let sidenavWidth: CGFloat = 42
        static let rightPanelWidth: CGFloat = 520
        static let sidebarMin: CGFloat = 200
        static let sidebarMax: CGFloat = 320
        static let tabMin: CGFloat = 100
        static let tabMax: CGFloat = 180
    }

    // MARK: - Typography

    enum Font {
        /// Primary text size — derived from the user's global base font size.
        static var body: CGFloat {
            Preferences.shared.globalFontSize - 1
        }
        /// Secondary text size — derived from the user's global base font size.
        static var caption: CGFloat {
            Preferences.shared.globalFontSize - 2
        }
        /// Toolbar and tab bar icon size (fixed).
        static let icon: CGFloat = 16
        /// Small icon size (close buttons, chevrons in search) (fixed).
        static let iconSmall: CGFloat = 11

        // MARK: - Styled Font Helpers

        /// The user's chosen global font family.
        private static var family: FontFamily {
            FontFamily(rawValue: Preferences.shared.globalFontFamily) ?? .system
        }

        /// Returns a SwiftUI `Font` with the correct design for the user's chosen family.
        static func styled(size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: family.swiftUIDesign)
        }

        /// Body-sized styled font.
        static var styledBody: SwiftUI.Font {
            styled(size: body)
        }

        /// Caption-sized styled font.
        static var styledCaption: SwiftUI.Font {
            styled(size: caption)
        }

        /// Returns an `NSFont` respecting the user's chosen font family.
        static func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
            let fam = family
            switch fam {
            case .system:
                return NSFont.systemFont(ofSize: size, weight: weight)
            case .serif:
                if let font = NSFont(name: "New York", size: size) {
                    return font
                }
                // Fallback: use serif descriptor
                let descriptor = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body)
                    .withDesign(.serif) ?? NSFontDescriptor()
                return NSFont(descriptor: descriptor.withSize(size), size: size)
                    ?? NSFont.systemFont(ofSize: size, weight: weight)
            case .sansSerif:
                return NSFont.systemFont(ofSize: size, weight: weight)
            }
        }
    }

    // MARK: - Chat Typography
    //
    // Inspired by Bridge.app's type scale: precise weight ladder and
    // size contrast to create clear visual hierarchy in chat UI.

    enum ChatFont {
        /// Chat message body — respects user's font family.
        /// Weight .regular (400) for comfortable reading.
        static var messageBody: SwiftUI.Font {
            Font.styled(size: max(Font.body, 15), weight: .regular)
        }
        /// Chat header title — weight .semibold (600) for clear hierarchy.
        static var headerTitle: SwiftUI.Font {
            .system(size: 16, weight: .semibold)
        }
        /// Chat model switcher label — weight .medium (500) for interactive elements.
        static var modelLabel: SwiftUI.Font {
            Font.styled(size: 13, weight: .medium)
        }
        /// Badge / chip label (skill, reference) — medium weight, smaller size.
        static var badge: SwiftUI.Font {
            Font.styled(size: 12, weight: .medium)
        }
        /// Small metadata / caption in chat — light weight for de-emphasis.
        static var meta: SwiftUI.Font {
            Font.styled(size: 11, weight: .light)
        }
        /// Action button icon size.
        static let actionIconSize: CGFloat = 12
        /// Streaming indicator bar height.
        static let streamingBarHeight: CGFloat = 16
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
        static let standard: CGFloat = 9
        static let small: CGFloat = 4
        static let concave: CGFloat = 10
    }

    // MARK: - View Modifiers

    struct CoverCardModifier: ViewModifier {
        var shadow: Bool

        func body(content: Content) -> some View {
            content
                .cornerRadius(Radius.small)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small)
                        .fill(shadow ? Color(nsColor: .textBackgroundColor) : Color.primary.opacity(0.03))
                        .shadow(color: shadow ? .black.opacity(0.25) : .clear, radius: 6, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.small)
                        .stroke(Color.primary.opacity(shadow ? 0.1 : 0.08), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Annotation Colors

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

extension View {
    func coverCard(shadow: Bool) -> some View {
        modifier(OakStyle.CoverCardModifier(shadow: shadow))
    }
}
