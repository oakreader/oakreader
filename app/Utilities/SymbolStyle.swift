import AppKit

/// Centralizes how SF Symbols are styled across the app so icon sets read consistently.
enum SymbolStyle {
    /// Resolve a symbol name to its **filled** variant when one exists, falling back to the
    /// original otherwise. Keeps skill / provider icon rows uniformly filled even when an
    /// individual icon (or a not-in-repo / user-installed skill) declared the outline variant.
    static func filledName(_ name: String) -> String {
        guard !name.hasSuffix(".fill") else { return name }
        let filled = "\(name).fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil ? filled : name
    }

    /// Load a symbol image preferring its filled variant. Returns `nil` if the symbol is unknown.
    static func filled(_ name: String, accessibilityDescription: String?) -> NSImage? {
        NSImage(systemSymbolName: filledName(name), accessibilityDescription: accessibilityDescription)
    }

    /// Resolve a symbol name to its **outline** variant when one exists — the inverse of
    /// `filledName`. Used where a glyph sits beside regular-weight text (menu-style rows):
    /// a filled glyph outweighs 13pt regular type, which macOS menus never do.
    static func outlineName(_ name: String) -> String {
        guard name.hasSuffix(".fill") else { return name }
        let outline = String(name.dropLast(5))
        return NSImage(systemSymbolName: outline, accessibilityDescription: nil) != nil ? outline : name
    }

    /// Load a symbol image preferring its outline variant. Returns `nil` if the symbol is unknown.
    static func outline(_ name: String, accessibilityDescription: String?) -> NSImage? {
        NSImage(systemSymbolName: outlineName(name), accessibilityDescription: accessibilityDescription)
    }
}
