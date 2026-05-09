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

// MARK: - Popup Labeled Button (icon + text label, hover highlight)

class PopupLabeledButton: NSView {
    private let onClick: () -> Void
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let iconView: NSImageView
    private let labelField: NSTextField

    init(systemImage: String, title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.iconView = NSImageView()
        self.labelField = NSTextField(labelWithString: title)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true

        if let img = NSImage(systemSymbolName: systemImage, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        labelField.font = .systemFont(ofSize: 11, weight: .medium)
        labelField.textColor = .secondaryLabelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(labelField)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            labelField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 3),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Loading State

    private var spinner: NSProgressIndicator?
    private(set) var isLoading = false

    func showLoading() {
        guard !isLoading else { return }
        isLoading = true
        iconView.isHidden = true

        let sp = NSProgressIndicator()
        sp.style = .spinning
        sp.controlSize = .small
        sp.isIndeterminate = true
        sp.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sp)
        NSLayoutConstraint.activate([
            sp.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            sp.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            sp.widthAnchor.constraint(equalToConstant: 14),
            sp.heightAnchor.constraint(equalToConstant: 14),
        ])
        sp.startAnimation(nil)
        spinner = sp
    }

    func hideLoading() {
        guard isLoading else { return }
        isLoading = false
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil
        iconView.isHidden = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        iconView.contentTintColor = .labelColor
        labelField.textColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
        iconView.contentTintColor = .secondaryLabelColor
        labelField.textColor = .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLoading else { return }
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        guard !isLoading else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onClick()
        }
        layer?.backgroundColor = isHovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : nil
    }
}

// MARK: - Popup Icon Button (icon-only, hover highlight)

class PopupIconButton: NSView {
    private let onClick: () -> Void
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private let iconView: NSImageView

    init(systemImage: String, accessibilityLabel: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.iconView = NSImageView()
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))

        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
        ])

        if let img = NSImage(systemSymbolName: systemImage, accessibilityDescription: accessibilityLabel) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
        ])

        toolTip = accessibilityLabel
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateImage(systemImage: String) {
        if let img = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            iconView.image = img.withSymbolConfiguration(config)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        iconView.contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
        iconView.contentTintColor = .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onClick()
        }
        layer?.backgroundColor = isHovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : nil
    }
}
