import AppKit

/// Row view for a single command in the palette.
///
/// Layout: `[icon]  Title          Category   ⌘K`
///
/// Uses `draw(_:)` for the selection/hover highlight so that
/// dynamic NSColors automatically adapt to light / dark mode.
final class CommandPaletteRowView: NSView {

    var onClick: (() -> Void)?
    var onHover: (() -> Void)?

    // Subviews
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeBackground = BadgePillView()
    private let categoryLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    // State
    private(set) var isSelected = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup

    private func setup() {
        // Icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Title – 13pt regular (primary)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // Category badge
        badgeBackground.translatesAutoresizingMaskIntoConstraints = false
        categoryLabel.translatesAutoresizingMaskIntoConstraints = false
        categoryLabel.font = .systemFont(ofSize: 10, weight: .medium)
        categoryLabel.textColor = .secondaryLabelColor
        categoryLabel.setContentHuggingPriority(.required, for: .horizontal)
        categoryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeBackground.addSubview(categoryLabel)

        // Shortcut – 11pt regular
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = .systemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(badgeBackground)
        addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            // Icon (16×16, padded from left)
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            // Title
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Badge pill (with inner category label)
            badgeBackground.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10
            ),
            badgeBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            categoryLabel.topAnchor.constraint(equalTo: badgeBackground.topAnchor, constant: 2),
            categoryLabel.bottomAnchor.constraint(equalTo: badgeBackground.bottomAnchor, constant: -2),
            categoryLabel.leadingAnchor.constraint(equalTo: badgeBackground.leadingAnchor, constant: 6),
            categoryLabel.trailingAnchor.constraint(equalTo: badgeBackground.trailingAnchor, constant: -6),

            // Shortcut
            shortcutLabel.leadingAnchor.constraint(equalTo: badgeBackground.trailingAnchor, constant: 10),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    // MARK: - Configure

    func configure(with command: PaletteCommand) {
        if let img = NSImage(systemSymbolName: command.icon, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            iconView.image = img.withSymbolConfiguration(config)
            iconView.contentTintColor = .secondaryLabelColor
        }
        titleLabel.stringValue = command.title
        categoryLabel.stringValue = command.category.rawValue
        shortcutLabel.stringValue = command.shortcut
        shortcutLabel.isHidden = command.shortcut.isEmpty
    }

    // MARK: - Selection

    func setSelected(_ selected: Bool) {
        isSelected = selected
        needsDisplay = true
    }

    // MARK: - Drawing (highlight)

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            let rect = bounds.insetBy(dx: 6, dy: 1)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        } else if isHovered {
            let rect = bounds.insetBy(dx: 6, dy: 1)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
    }

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) { onClick?() }
    }
}

// MARK: - Badge Pill (appearance-adaptive rounded background)

private final class BadgePillView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}
