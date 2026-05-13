import AppKit

/// A floating panel that shows filtered `ChatCompletionItem`s above the cursor.
/// Adapts the `SlashCommandPanel` pattern from MarkdownTextView with glass/vibrancy styling.
final class ChatCompletionPanel: NSPanel, AppResignDismissable {

    var resignObserver: NSObjectProtocol?

    private var allItems: [ChatCompletionItem]
    private var filtered: [ChatCompletionItem]
    private var selectedIndex = 0
    private var rowViews: [ChatCompletionRowView] = []
    private let stackView = NSStackView()
    private let onSelect: (ChatCompletionItem) -> Void

    fileprivate static let panelWidth: CGFloat = 320
    fileprivate static let rowHeight: CGFloat = 30
    private static let maxVisible = 6

    var selectedItem: ChatCompletionItem? {
        guard selectedIndex >= 0, selectedIndex < filtered.count else { return nil }
        return filtered[selectedIndex]
    }

    var filteredCount: Int { filtered.count }

    // MARK: - Init

    init(items: [ChatCompletionItem], at screenPoint: NSPoint, onSelect: @escaping (ChatCompletionItem) -> Void) {
        self.allItems = items
        self.filtered = items
        self.onSelect = onSelect
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true
        collectionBehavior = [.transient, .ignoresCycle]

        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Keep this popup simple and predictable. The previous glass container
        // inside a scroll view produced nested/offset backgrounds around slash
        // skill results. A plain rounded container matches the app chrome and
        // avoids visual artifacts.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        container.layer?.masksToBounds = true
        container.addSubview(stackView)
        contentView = container

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        buildRows()
        updateSelection()
        sizeAndPosition(at: screenPoint)

        observeAppResign()
        orderFront(nil)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; self.animator().alphaValue = 1 }
    }

    deinit {
        removeAppResignObserver()
    }

    // MARK: - Filtering

    func filter(query: String) {
        filtered = query.isEmpty ? allItems : allItems.filter { $0.matches(query: query) }
        selectedIndex = 0
        buildRows()
        updateSelection()
        let origin = frame.origin
        sizeAndPosition(at: NSPoint(x: origin.x, y: origin.y + frame.height))
    }

    // MARK: - Navigation

    func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + filtered.count) % filtered.count
        updateSelection()
    }

    func dismiss() {
        removeAppResignObserver()
        NSAnimationContext.runAnimationGroup(
            { $0.duration = 0.08; self.animator().alphaValue = 0 },
            completionHandler: { self.orderOut(nil) }
        )
    }

    // MARK: - Private

    private func buildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = filtered.map { item in
            let row = ChatCompletionRowView(item: item) { [weak self] in self?.onSelect(item) }
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            return row
        }
    }

    private func updateSelection() {
        for (i, row) in rowViews.enumerated() {
            row.setHighlighted(i == selectedIndex)
        }
        if selectedIndex < rowViews.count {
            rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
        }
    }

    private func sizeAndPosition(at topPt: NSPoint) {
        let visibleCount = min(filtered.count, Self.maxVisible)
        let h = CGFloat(visibleCount) * Self.rowHeight + 8
        // `topPt` is the chat input's top-left point in screen coordinates.
        setFrame(NSRect(x: topPt.x, y: topPt.y, width: Self.panelWidth, height: h), display: true)
    }
}

// MARK: - Row View

private final class ChatCompletionRowView: NSView {
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?

    init(item: ChatCompletionItem, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: ChatCompletionPanel.panelWidth, height: ChatCompletionPanel.rowHeight))
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ChatCompletionPanel.rowHeight).isActive = true

        // Icon
        let icon = NSImageView(frame: .zero)
        if let img = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.label) {
            icon.image = img.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        }
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        // Label
        let label = NSTextField(labelWithString: item.displayText)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        // Description
        let desc = NSTextField(labelWithString: item.description)
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.translatesAutoresizingMaskIntoConstraints = false
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        desc.lineBreakMode = .byTruncatingTail

        addSubview(icon)
        addSubview(label)
        addSubview(desc)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            desc.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 7),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            desc.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setHighlighted(_ on: Bool) {
        // Liquid-glass style: avoid the old blue selection fill; use a subtle
        // neutral lift so the row still has keyboard/mouse focus affordance.
        layer?.backgroundColor = on
            ? NSColor.labelColor.withAlphaComponent(0.07).cgColor
            : NSColor.white.withAlphaComponent(0.001).cgColor
        layer?.cornerRadius = 8
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) { setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}
