import AppKit

// MARK: - Popup Panel Dismiss-on-Resign

/// Panels conforming to this protocol automatically dismiss when the app loses focus.
protocol AppResignDismissable: NSPanel {
    var resignObserver: NSObjectProtocol? { get set }
    func dismiss()
}

extension AppResignDismissable {
    func observeAppResign() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    func removeAppResignObserver() {
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
    }
}

// MARK: - Popup Style

enum PopupStyle {
    /// Neutral hover/press washes. Accent color is reserved for
    /// selected/active state — never plain hover.
    static var hoverBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.07) }
    static var pressedBackground: NSColor { NSColor.labelColor.withAlphaComponent(0.12) }
}

// MARK: - Glass Container Factory

/// Creates a popup container with Liquid Glass on macOS 26+, falling back to NSVisualEffectView.
/// Defaults to a capsule — floating glass bars are designed around fully-rounded
/// shapes, not small fixed radii.
func makePopupGlassContainer(content: NSView, cornerRadius: CGFloat? = nil) -> NSView {
    let radius = cornerRadius ?? content.fittingSize.height / 2
    let container: NSView
    var rim: NSView?
    if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = radius
        container = glass
    } else {
        let vev = NSVisualEffectView()
        vev.material = .popover
        vev.state = .active
        vev.wantsLayer = true
        vev.layer?.cornerRadius = radius
        container = vev
        // Hand-clipping the material loses the system popover's edge
        // treatment; restore the glass rim by hand.
        rim = PopupRimView(cornerRadius: radius)
    }
    container.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: container.topAnchor),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    if let rim {
        rim.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rim)
        NSLayoutConstraint.activate([
            rim.topAnchor.constraint(equalTo: container.topAnchor),
            rim.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rim.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rim.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }
    return container
}

/// Dark outer hairline + light inner highlight around the glass edge —
/// the depth cue system popovers draw and a plain masked layer lacks.
private final class PopupRimView: NSView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let outer = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
            xRadius: cornerRadius, yRadius: cornerRadius
        )
        outer.lineWidth = 0.5
        NSColor.black.withAlphaComponent(isDark ? 0.5 : 0.12).setStroke()
        outer.stroke()

        let innerRadius = max(cornerRadius - 0.5, 0)
        let inner = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            xRadius: innerRadius, yRadius: innerRadius
        )
        inner.lineWidth = 0.5
        NSColor.white.withAlphaComponent(isDark ? 0.12 : 0.35).setStroke()
        inner.stroke()
    }
}

// MARK: - Popup Separator

/// Short, faint vertical divider between popup button groups. 1pt line inside
/// an 11pt wrapper (~5pt breathing room each side); shorter than the buttons
/// so it reads as a group boundary without chopping the bar into boxes.
func makePopupVerticalSeparator() -> NSView {
    let sep = NSBox()
    sep.boxType = .separator
    sep.translatesAutoresizingMaskIntoConstraints = false
    let wrapper = NSView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    wrapper.alphaValue = 0.7
    wrapper.addSubview(sep)
    NSLayoutConstraint.activate([
        wrapper.widthAnchor.constraint(equalToConstant: 11),
        wrapper.heightAnchor.constraint(equalToConstant: 14),
        sep.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
        sep.topAnchor.constraint(equalTo: wrapper.topAnchor),
        sep.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        sep.widthAnchor.constraint(equalToConstant: 1),
    ])
    return wrapper
}

// MARK: - Popup Entrance Animation

/// Fade + 4pt rise into the final position — popover-style entrance instead
/// of a flat fade. Call after the panel's final frame origin is set.
func animatePopupEntrance(_ panel: NSPanel) {
    let finalFrame = panel.frame
    panel.setFrameOrigin(NSPoint(x: finalFrame.origin.x, y: finalFrame.origin.y - 4))
    panel.alphaValue = 0
    panel.orderFront(nil)
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.16
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
        panel.animator().setFrame(finalFrame, display: true)
    }
}

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
        layer?.cornerRadius = 16
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
        layer?.backgroundColor = PopupStyle.hoverBackground.cgColor
        iconView.contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
        iconView.contentTintColor = .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = PopupStyle.pressedBackground.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) {
            onClick()
        }
        layer?.backgroundColor = isHovered
            ? PopupStyle.hoverBackground.cgColor
            : nil
    }
}

// MARK: - "Copied" toast

/// Brief HUD toast centered in the key window confirming a clipboard copy.
/// Shared by the selection popups (area / HTML) so the look and timing stay in
/// one place. Fades in (0.2s), holds (1.5s), fades out (0.3s); mouse-transparent.
@MainActor
func showCopiedToast(message: String = "Copied to clipboard") {
    showHUDToast(message: message)
}

/// General HUD toast — same glass look/timing as `showCopiedToast`, but the icon,
/// tint and message are caller-supplied and the panel sizes to fit the text. Used
/// for non-copy feedback such as a failed citation jump.
@MainActor
func showHUDToast(
    message: String,
    systemImage: String = "checkmark.circle.fill",
    tint: NSColor = .systemGreen
) {
    guard let window = NSApp.keyWindow else { return }

    let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    let textWidth = (message as NSString).size(withAttributes: [.font: font]).width
    let width = min(max(160, ceil(textWidth) + 56), 360)
    let labelWidth = width - 50
    let height: CGFloat = 36

    let toast = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    toast.isOpaque = false
    toast.backgroundColor = .clear
    toast.level = .floating
    toast.ignoresMouseEvents = true

    let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    bg.material = .hudWindow
    bg.state = .active
    bg.wantsLayer = true
    bg.layer?.cornerRadius = 8

    let icon = NSImageView(frame: NSRect(x: 12, y: 6, width: 24, height: 24))
    if let img = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.image = img.withSymbolConfiguration(config)
        icon.contentTintColor = tint
    }
    bg.addSubview(icon)

    let label = NSTextField(labelWithString: message)
    label.font = font
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.frame = NSRect(x: 40, y: 8, width: labelWidth, height: 20)
    bg.addSubview(label)

    toast.contentView = bg

    let windowFrame = window.frame
    let toastX = windowFrame.midX - width / 2
    let toastY = windowFrame.midY - height / 2
    toast.setFrameOrigin(NSPoint(x: toastX, y: toastY))
    toast.orderFront(nil)

    toast.alphaValue = 0
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.2
        toast.animator().alphaValue = 1
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            toast.animator().alphaValue = 0
        }, completionHandler: {
            toast.orderOut(nil)
        })
    }
}

// MARK: - Color swatch sub-panel

/// Builds the floating "pick a highlight color" sub-panel shown beneath a
/// selection popup — a horizontal row of `ColorDotView` swatches in a glass
/// container. Shared by the text / area / HTML selection popups; the caller
/// owns positioning, the `colorSubPanel` reference, and the fade-in (those
/// legitimately differ per popup). `onSelect` receives the swatch index.
@MainActor
func makeColorSwatchPanel(
    swatches: [(NSColor, String)],
    aqua: Bool = false,
    onSelect: @escaping (Int) -> Void
) -> NSPanel {
    let colorStack = NSStackView()
    colorStack.orientation = .horizontal
    colorStack.spacing = 8
    colorStack.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)

    for (index, swatch) in swatches.enumerated() {
        let dot = ColorDotView(color: swatch.0, size: 20) { onSelect(index) }
        dot.toolTip = swatch.1
        colorStack.addArrangedSubview(dot)
    }

    let container = makePopupGlassContainer(content: colorStack)

    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.hasShadow = true
    panel.ignoresMouseEvents = false
    if aqua { panel.appearance = NSAppearance(named: .aqua) }
    panel.contentView = container
    panel.setContentSize(container.fittingSize)
    return panel
}
