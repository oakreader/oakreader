import AppKit
import SwiftUI

/// Single source of truth for the look of the app's suggestion dropdowns, shared by
/// the chat composer's `ChatCompletionPanel` (AppKit) and the note composer's `@`/`#`
/// pickers (SwiftUI) so the two stay pixel-identical instead of drifting apart.
///
/// The shape started as a pixel-by-pixel reproduction of Dia 1.36's command-bar
/// suggestion panel (`Attachments.AttachmentSuggestionsViewController` inside an
/// `ARCUI.PopoverBackgroundView`), then moved toward macOS's own menu conventions
/// where Dia's numbers didn't survive OUR content — long sentence-length skill
/// descriptions, which Dia's short right-aligned source labels never had to hold:
///   • Card: white `#FFFFFF` / dark `#161617`, 10pt continuous corners, drop shadow,
///     and NO stroke in light (an `NSMenu` has none either).
///   • Row: 26pt tall, 13.5pt outline glyph shown directly (NO grey tile, and NOT the
///     `.fill` variant — filled glyphs outweigh 13pt regular text), 7pt icon leading,
///     7pt icon→title gap, 13pt title, 11pt description inline after it.
///   • Selection: a light grey band (black@7% / white@12%) with the row's own text
///     colours, corners concentric with the card, 5pt horizontal inset.
///   • Header: UPPERCASE 11pt semibold grey tracked ~0.5.
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

    /// Card border. A real `NSMenu` draws NO stroke — its drop shadow alone separates
    /// the card from what's behind it — and a 4%-black hairline was too faint to define
    /// an edge yet strong enough to muddy the shadow's falloff. So: none in light.
    /// Dark keeps a hairline, which it genuinely needs: a near-black card on a dark pane
    /// has no shadow contrast to fall back on.
    var border: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.08) : .clear
    }

    /// Selected-row fill.
    ///
    /// A light grey band. This was Dia's measured `#6A9FF9`, then the user's own
    /// accent — both of which shouted: the panel opens inches above the
    /// composer's chips, and a saturated row was the loudest thing on screen.
    /// Grey lets the row read as selected without taking over. Stronger in dark,
    /// where the card is already near-black and a 7% wash would vanish.
    var selectionFill: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.12)
               : NSColor.black.withAlphaComponent(0.07)
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

    /// Resolve a dynamic system colour against THIS palette's appearance and flatten it
    /// to sRGB, so a `CALayer` can store the result as a static `.cgColor`.
    private func resolved(_ make: () -> NSColor) -> NSColor {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance
        var out = make()
        appearance.performAsCurrentDrawingAppearance {
            out = make().usingColorSpace(.sRGB) ?? make()
        }
        return out
    }

    // MARK: - Colours (SwiftUI accessors)

    var panelBackgroundColor: Color { Color(nsColor: panelBackground) }
    var selectionFillColor: Color { Color(nsColor: selectionFill) }
    var titleColor: Color { Color(nsColor: title) }
    var secondaryColor: Color { Color(nsColor: secondary) }
    var headerColor: Color { Color(nsColor: header) }

    // MARK: - Metrics

    /// Shared layout metrics for a dropdown row/card, so the AppKit panel and the
    /// SwiftUI pickers measure to the same pixels.
    enum Metrics {
        static let rowHeight: CGFloat = 26
        static let headerHeight: CGFloat = 22
        /// Card corner. Was Dia's measured 14, which is a LARGER arc than the 5-6pt
        /// content inset below it — so the section header and the first/last rows sat
        /// *inside* the curve instead of clear of it. A real `NSMenu` uses ~10 here,
        /// which clears the inset and reads calmer at this size.
        static let cornerRadius: CGFloat = 10
        static let horizontalInset: CGFloat = 5
        static let verticalInset: CGFloat = 5
        /// Glyph point size shown directly (no tile).
        static let iconPointSize: CGFloat = 13.5
        /// Square the glyph is centred in.
        static let iconFrame: CGFloat = 15
        /// Icon's leading pad inside the row. With `horizontalInset` this puts the icon
        /// column 12pt from the card edge — keep the two summing to 12 if either moves.
        static let iconLeading: CGFloat = 7
        static let iconToTitle: CGFloat = 7
        /// Concentric with the card: `cornerRadius - horizontalInset`. Keep it that way
        /// when either of those changes, or the pill's corner stops tracking the card's.
        static let selectionRadius: CGFloat = cornerRadius - horizontalInset
        /// Gap between a row's title and its inline description.
        static let titleToDescription: CGFloat = 8
        /// Row's own trailing padding, inside the card inset — mirrors `iconLeading`
        /// so the row's content is optically centred at 12pt from either card edge.
        static let rowTrailingInset: CGFloat = 7
        static let titleSize: CGFloat = 13
        static let secondarySize: CGFloat = 11
    }
}
