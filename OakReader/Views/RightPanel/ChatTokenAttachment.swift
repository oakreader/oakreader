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
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let iconSize: CGFloat = 12
    private static let hPad: CGFloat = 6
    private static let iconTextGap: CGFloat = 3
    private static let vPad: CGFloat = 2
    private static let cornerRadius: CGFloat = 4

    init(item: ChatCompletionItem) {
        self.item = item
        super.init()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    // MARK: - Sizing

    override func cellSize() -> NSSize {
        let textWidth = (item.displayText as NSString).size(
            withAttributes: [.font: Self.font]
        ).width
        let width = Self.hPad + Self.iconSize + Self.iconTextGap + textWidth + Self.hPad
        let height = max(Self.font.boundingRectForFont.height, Self.iconSize) + Self.vPad * 2
        return NSSize(width: ceil(width), height: ceil(height))
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -5)
    }

    // MARK: - Drawing

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let accentColor = NSColor.controlAccentColor

        // Background fill
        let bgColor = accentColor.withAlphaComponent(0.12)
        let bgPath = NSBezierPath(roundedRect: cellFrame, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        bgColor.setFill()
        bgPath.fill()

        // Border
        let borderColor = accentColor.withAlphaComponent(0.35)
        borderColor.setStroke()
        let insetRect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let borderPath = NSBezierPath(roundedRect: insetRect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        borderPath.lineWidth = 1
        borderPath.stroke()

        // Icon
        let iconY = cellFrame.minY + (cellFrame.height - Self.iconSize) / 2
        let iconRect = NSRect(
            x: cellFrame.minX + Self.hPad,
            y: iconY,
            width: Self.iconSize,
            height: Self.iconSize
        )
        if let imagePath = item.imagePath,
           let image = NSImage(contentsOfFile: imagePath) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: iconRect).addClip()
            image.draw(
                in: iconRect,
                from: NSRect(origin: .zero, size: image.size),
                operation: .sourceOver,
                fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()
        } else if let image = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.label) {
            let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .medium)
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.8)
        }

        // Label text
        let textX = iconRect.maxX + Self.iconTextGap
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: accentColor
        ]
        let textSize = (item.displayText as NSString).size(withAttributes: attrs)
        let textY = cellFrame.minY + (cellFrame.height - textSize.height) / 2
        let textRect = NSRect(x: textX, y: textY, width: textSize.width, height: textSize.height)
        (item.displayText as NSString).draw(in: textRect, withAttributes: attrs)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool {
        false
    }
}
