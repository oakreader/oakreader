import AppKit

// MARK: - Color Dot (OakReader-style round swatch)

class ColorDotView: NSView {
    private let color: NSColor
    private let onClick: () -> Void
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(color: NSColor, size: CGFloat, onClick: @escaping () -> Void) {
        self.color = color
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isHovered ? 0.5 : 1.0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(ovalIn: rect)
        color.setFill()
        path.fill()

        if isHovered {
            NSColor.controlTextColor.withAlphaComponent(0.4).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // visual feedback
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onClick()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
}

// MARK: - Popup Action Button (icon + label, OakReader-style)

class PopupActionButton: NSButton {
    private let onClick: () -> Void

    init(systemImage: String, title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)

        self.title = title
        isBordered = true
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = NSFont.systemFont(ofSize: 11, weight: .regular)
        contentTintColor = .labelColor

        if let img = NSImage(systemSymbolName: systemImage, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            self.image = img.withSymbolConfiguration(config)
        }
        imagePosition = .imageLeading
        imageHugsTitle = true

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true

        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() {
        onClick()
    }
}
