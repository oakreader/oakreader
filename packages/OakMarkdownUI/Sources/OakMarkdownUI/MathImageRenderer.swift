import SwiftUI
import AppKit
import SwiftUIMath

/// Rasterizes a LaTeX string to an `NSImage` for inline embedding in an AppKit
/// text view — used by the note editor's live `$…$` rendering, where math has to
/// sit inside an `NSTextStorage` run rather than a SwiftUI view.
///
/// This lives in `OakMarkdownUI` (not the app target) because that's where the
/// `SwiftUIMath` dependency already is — the same engine `MathBlockView` uses, so
/// editor and rendered card stay visually identical. Results are cached by
/// (latex, font size, appearance, color) so repeated layout/selection passes are
/// free; `MainActor`-isolated because `ImageRenderer` is.
@MainActor
public enum MathImageRenderer {
    private struct Key: Hashable {
        let latex: String
        let fontSize: CGFloat
        let isDark: Bool
        let colorRGBA: UInt32
    }

    private static var cache: [Key: NSImage] = [:]

    /// Render `latex` (delimiters already stripped) at `fontSize`, tinted `color`.
    /// Returns `nil` for empty/unrenderable input (so the caller can fall back to
    /// showing the raw source).
    public static func image(
        latex: String,
        fontSize: CGFloat,
        color: NSColor,
        display: Bool = false
    ) -> NSImage? {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isDark = (NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = Key(latex: trimmed, fontSize: fontSize, isDark: isDark, colorRGBA: color.rgbaFingerprint)
        if let hit = cache[key] { return hit }

        let view = Math(trimmed)
            .mathTypesettingStyle(display ? .display : .text)
            .mathFont(.init(name: .latinModern, size: fontSize))
            .foregroundStyle(Color(nsColor: color))

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage, image.size.width > 0, image.size.height > 0 else { return nil }

        cache[key] = image
        return image
    }
}

private extension NSColor {
    /// A 32-bit fingerprint good enough to bust the cache on a theme/appearance color change.
    var rgbaFingerprint: UInt32 {
        guard let c = usingColorSpace(.deviceRGB) else { return 0 }
        let r = UInt32((c.redComponent * 255).rounded()) & 0xFF
        let g = UInt32((c.greenComponent * 255).rounded()) & 0xFF
        let b = UInt32((c.blueComponent * 255).rounded()) & 0xFF
        let a = UInt32((c.alphaComponent * 255).rounded()) & 0xFF
        return (r << 24) | (g << 16) | (b << 8) | a
    }
}
