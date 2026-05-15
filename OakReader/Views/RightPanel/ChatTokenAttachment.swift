import AppKit

/// An `NSTextAttachment` that stores a `ChatCompletionItem` and draws a
/// Codex-style inline token chip: rounded rect with accent fill, accent border,
/// SF Symbol icon, and label text.
final class ChatTokenAttachment: NSTextAttachment {

    let item: ChatCompletionItem

    init(item: ChatCompletionItem) {
        self.item = item
        super.init(data: nil, ofType: nil)
        self.attachmentCell = ChatTokenCell(item: item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Token Cell

private final class ChatTokenCell: NSTextAttachmentCell {

    private let item: ChatCompletionItem
    private static let font = NSFont.systemFont(ofSize: 16, weight: .regular)
    private static let iconSize: CGFloat = 18
    private static let hPad: CGFloat = 6
    private static let iconTextGap: CGFloat = 3
    private static let vPad: CGFloat = 2
    private static let cornerRadius: CGFloat = 4
    private static let maxTextWidth: CGFloat = 160

    init(item: ChatCompletionItem) {
        self.item = item
        super.init()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    // MARK: - Helpers

    private var truncatedLabel: String {
        let fullWidth = (item.label as NSString).size(withAttributes: [.font: Self.font]).width
        guard fullWidth > Self.maxTextWidth else { return item.label }

        var truncated = item.label
        while !truncated.isEmpty {
            truncated = String(truncated.dropLast())
            let testWidth = ((truncated + "…") as NSString).size(withAttributes: [.font: Self.font]).width
            if testWidth <= Self.maxTextWidth {
                return truncated + "…"
            }
        }
        return "…"
    }

    // MARK: - Sizing

    override func cellSize() -> NSSize {
        let fullTextWidth = (item.label as NSString).size(withAttributes: [.font: Self.font]).width
        let textWidth = min(fullTextWidth, Self.maxTextWidth)
        let width = Self.hPad + Self.iconSize + Self.iconTextGap + textWidth + Self.hPad
        let height = max(Self.font.boundingRectForFont.height, Self.iconSize) + Self.vPad * 2
        return NSSize(width: ceil(width), height: ceil(height))
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -5)
    }

    // MARK: - Drawing

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let rawAccent = NSColor.controlAccentColor
        let softAccent = rawAccent
            .blended(withFraction: 0.5, of: .tertiaryLabelColor) ?? rawAccent

        // Background fill + border
        let bgRect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bgRect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        softAccent.withAlphaComponent(0.08).setFill()
        path.fill()
        softAccent.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        // Icon — tint to match label color
        let iconY = cellFrame.minY + (cellFrame.height - Self.iconSize) / 2
        let iconRect = NSRect(
            x: cellFrame.minX + Self.hPad,
            y: iconY,
            width: Self.iconSize,
            height: Self.iconSize
        )
        let iconName = item.icon.hasSuffix(".fill") ? item.icon : "\(item.icon).fill"
        let resolvedName = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) != nil ? iconName : item.icon
        if let image = NSImage(systemSymbolName: resolvedName, accessibilityDescription: item.label) {
            let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .regular)
            let configured = image.withSymbolConfiguration(config) ?? image
            let tinted = NSImage(size: iconRect.size, flipped: false) { drawRect in
                configured.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                softAccent.set()
                drawRect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: iconRect)
        }

        // Label text (truncated with ellipsis if too wide)
        let displayLabel = truncatedLabel
        let textX = iconRect.maxX + Self.iconTextGap
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: softAccent
        ]
        let textSize = (displayLabel as NSString).size(withAttributes: attrs)
        let textY = cellFrame.minY + (cellFrame.height - textSize.height) / 2
        let textRect = NSRect(x: textX, y: textY, width: textSize.width, height: textSize.height)
        (displayLabel as NSString).draw(in: textRect, withAttributes: attrs)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool {
        false
    }
}
