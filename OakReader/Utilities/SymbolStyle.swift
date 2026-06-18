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
}
