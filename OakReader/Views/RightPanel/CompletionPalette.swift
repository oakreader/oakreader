import AppKit
import SwiftUI

/// Single source of truth for the look of the app's suggestion dropdowns, shared by
/// the chat composer's `ChatCompletionPanel` (AppKit) and the note composer's `@`/`#`
/// pickers (SwiftUI) so the two stay pixel-identical instead of drifting apart.
///
/// Every value was reverse-engineered pixel-by-pixel from Dia 1.36's command-bar
/// suggestion panel (`Attachments.AttachmentSuggestionsViewController` inside an
/// `ARCUI.PopoverBackgroundView`):
///   • Card: white `#FFFFFF` / dark `#161617`, 14pt continuous corners, hairline
///     border, soft drop shadow.
///   • Row: 26pt tall, 13.5pt glyph shown directly (NO grey tile), 6pt icon leading,
///     7pt icon→title gap, 13pt title.
///   • Selection: accent-blue pill (`#6A9FF9` / `#2B57B7`) with WHITE text/icon,
///     8pt corners, 6pt horizontal inset from the card edge.
///   • Header: UPPERCASE 11pt semibold grey (`#BEBEBE`) tracked ~0.5.
///
/// NSColor is the canonical form (the AppKit panel renders with `CALayer`s); the
/// `…Color` accessors derive the SwiftUI equivalents losslessly via `Color(nsColor:)`.
struct CompletionPalette {
    let isDark: Bool

    /// Build from the app's current effective appearance.
    static var current: CompletionPalette {
        CompletionPalette(isDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    // MARK: - Colours (NSColor canonical)

    /// Card fill. Dia: pure white in light, a deep near-black `#161617` in dark
    /// (the popover reads *darker* than the surrounding command-bar chrome).
    var panelBackground: NSColor {
        isDark ? NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x17 / 255, alpha: 1)
               : .white
    }

    /// Hairline card border — barely-there in light, a soft top-edge highlight in dark.
    var border: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.06)
               : NSColor.black.withAlphaComponent(0.04)
    }

    /// Selected-row fill. Measured pixel mode: `#6A9FF9` (light) / `#2B57B7` (dark).
    var selectionFill: NSColor {
        isDark ? NSColor(srgbRed: 0x2B / 255, green: 0x57 / 255, blue: 0xB7 / 255, alpha: 1)
               : NSColor(srgbRed: 0x6A / 255, green: 0x9F / 255, blue: 0xF9 / 255, alpha: 1)
    }

    /// Title text. `#1A1A1A` / `#E6E7E7` — i.e. ~labelColor.
    var title: NSColor {
        isDark ? NSColor(white: 0.91, alpha: 1) : NSColor(white: 0.10, alpha: 1)
    }

    /// Secondary / right-aligned source text and inline counts.
    var secondary: NSColor {
        isDark ? NSColor(white: 0.56, alpha: 1) : NSColor(white: 0.58, alpha: 1)
    }

    /// Section-header grey. Measured `#BEBEBE` in light; dimmer in dark.
    var header: NSColor {
        isDark ? NSColor(white: 0.50, alpha: 1) : NSColor(white: 0.72, alpha: 1)
    }

    /// Text/icon colour on the accent selection pill.
    var onSelectionText: NSColor { .white }
    var onSelectionSecondary: NSColor { NSColor.white.withAlphaComponent(0.82) }

    // MARK: - Colours (SwiftUI accessors)

    var panelBackgroundColor: Color { Color(nsColor: panelBackground) }
    var borderColor: Color { Color(nsColor: border) }
    var selectionFillColor: Color { Color(nsColor: selectionFill) }
    var titleColor: Color { Color(nsColor: title) }
    var secondaryColor: Color { Color(nsColor: secondary) }
    var headerColor: Color { Color(nsColor: header) }
    var onSelectionTextColor: Color { Color(nsColor: onSelectionText) }
    var onSelectionSecondaryColor: Color { Color(nsColor: onSelectionSecondary) }

    // MARK: - Metrics

    /// Shared layout metrics for a dropdown row/card, so the AppKit panel and the
    /// SwiftUI pickers measure to the same pixels.
    enum Metrics {
        static let rowHeight: CGFloat = 26
        static let headerHeight: CGFloat = 22
        static let cornerRadius: CGFloat = 14
        static let horizontalInset: CGFloat = 6
        static let verticalInset: CGFloat = 5
        /// Glyph point size shown directly (no tile).
        static let iconPointSize: CGFloat = 13.5
        /// Square the glyph is centred in.
        static let iconFrame: CGFloat = 15
        static let iconLeading: CGFloat = 6
        static let iconToTitle: CGFloat = 7
        static let selectionRadius: CGFloat = 8
        static let titleSize: CGFloat = 13
        static let secondarySize: CGFloat = 11
    }
}
