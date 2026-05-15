import AppKit

/// A floating, sectioned completion panel for `/` commands.
/// The panel intentionally mirrors the chat composer width so the trigger UI
/// feels connected to the input instead of appearing as a detached menu.
final class ChatCompletionPanel: NSPanel, AppResignDismissable {

    var resignObserver: NSObjectProtocol?

    private var allItems: [ChatCompletionItem]
    private var filtered: [ChatCompletionItem]
    private var selectedIndex = 0
    private var rowViews: [ChatCompletionRowView] = []
    private let stackView = NSStackView()
    private let scrollView = NSScrollView()
    private let documentView = CompletionDocumentView()
    private var documentHeightConstraint: NSLayoutConstraint?
    private let onSelect: (ChatCompletionItem) -> Void

    /// Pre-built views keyed by item ID — avoids tearing down and recreating
    /// NSViews on every keystroke during incremental filtering.
    private var cachedRows: [String: ChatCompletionRowView] = [:]
    private var cachedHeaders: [String: ChatCompletionSectionHeaderView] = [:]
    private lazy var emptyView = ChatCompletionEmptyView()

    private let anchorPoint: NSPoint
    private let panelWidth: CGFloat
    private let windowFrame: NSRect

    fileprivate static let rowHeight: CGFloat = 26
    fileprivate static let headerHeight: CGFloat = 22
    fileprivate static let emptyHeight: CGFloat = 46
    private static let maxPanelHeight: CGFloat = 640
    private static let minPanelWidth: CGFloat = 300
    private static let maxPanelWidth: CGFloat = 680
    private static let horizontalInset: CGFloat = 14
    private static let verticalInset: CGFloat = 10

    var selectedItem: ChatCompletionItem? {
        guard selectedIndex >= 0, selectedIndex < filtered.count else { return nil }
        return filtered[selectedIndex]
    }

    var filteredCount: Int { filtered.count }

    // MARK: - Init

    init(
        items: [ChatCompletionItem],
        at screenPoint: NSPoint,
        width requestedWidth: CGFloat,
        windowFrame: NSRect,
        onSelect: @escaping (ChatCompletionItem) -> Void
    ) {
        self.allItems = items
        self.filtered = items
        self.anchorPoint = screenPoint
        self.panelWidth = min(max(requestedWidth, Self.minPanelWidth), Self.maxPanelWidth)
        self.windowFrame = windowFrame
        self.onSelect = onSelect

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        collectionBehavior = [.transient, .ignoresCycle]

        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        scrollView.documentView = documentView

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        container.layer?.masksToBounds = true
        container.addSubview(scrollView)
        contentView = container

        let heightConstraint = documentView.heightAnchor.constraint(equalToConstant: 10)
        documentHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            heightConstraint,

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor, constant: Self.verticalInset),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -Self.verticalInset),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: Self.horizontalInset),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -Self.horizontalInset),
        ])

        buildRows()
        updateSelection()
        sizeAndPosition()

        observeAppResign()
        orderFront(nil)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            self.animator().alphaValue = 1
        }
    }

    deinit {
        removeAppResignObserver()
    }

    // MARK: - Filtering

    func filter(query: String) {
        if query.isEmpty {
            filtered = allItems
        } else {
            filtered = allItems.filter { $0.matches(query: query) }
        }
        selectedIndex = filtered.isEmpty ? -1 : 0
        buildRows()
        updateSelection()
        sizeAndPosition()
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
            { context in
                context.duration = 0.08
                self.animator().alphaValue = 0
            },
            completionHandler: { self.orderOut(nil) }
        )
    }

    // MARK: - Private

    private var sectionedItems: [(title: String, items: [ChatCompletionItem])] {
        var sections: [(title: String, items: [ChatCompletionItem])] = []
        for item in filtered {
            if sections.last?.title == item.sectionTitle {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append((title: item.sectionTitle, items: [item]))
            }
        }
        return sections
    }

    private func buildRows() {
        // Detach all arranged subviews without destroying them
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews = []

        if filtered.isEmpty {
            stackView.addArrangedSubview(emptyView)
            pin(emptyView)
            updateDocumentHeight()
            return
        }

        for section in sectionedItems {
            let header = cachedHeaders[section.title] ?? {
                let h = ChatCompletionSectionHeaderView(title: section.title)
                cachedHeaders[section.title] = h
                return h
            }()
            stackView.addArrangedSubview(header)
            pin(header)

            for item in section.items {
                let row = cachedRows[item.id] ?? {
                    let r = ChatCompletionRowView(
                        item: item,
                        onHover: { [weak self] in
                            guard let self, let index = self.filtered.firstIndex(of: item) else { return }
                            self.selectedIndex = index
                            self.updateSelection()
                        },
                        onClick: { [weak self] in self?.onSelect(item) }
                    )
                    cachedRows[item.id] = r
                    return r
                }()
                stackView.addArrangedSubview(row)
                pin(row)
                rowViews.append(row)
            }
        }

        updateDocumentHeight()
    }

    /// Pin a view's leading/trailing to the stack without creating duplicate constraints.
    private func pin(_ view: NSView) {
        // Constraints are idempotent when the view is re-added to the same stack.
        // But creating duplicates is harmless for equality constraints — AutoLayout dedupes.
        view.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
    }

    private func updateSelection() {
        for (i, row) in rowViews.enumerated() {
            row.setHighlighted(i == selectedIndex)
        }
        guard selectedIndex >= 0, selectedIndex < rowViews.count else { return }
        rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds)
    }

    private func updateDocumentHeight() {
        documentHeightConstraint?.constant = contentHeight()
        documentView.needsLayout = true
        stackView.needsLayout = true
    }

    private func contentHeight() -> CGFloat {
        if filtered.isEmpty {
            return Self.verticalInset * 2 + Self.emptyHeight
        }
        let sections = sectionedItems
        let rows = filtered.count
        return Self.verticalInset * 2
            + CGFloat(sections.count) * Self.headerHeight
            + CGFloat(rows) * Self.rowHeight
    }

    private func sizeAndPosition() {
        // Constrain to the parent window frame so the panel never extends
        // beyond the application window edge.
        let constraintRect = windowFrame
        let margin: CGFloat = 8

        // Cap height to available space above the anchor within the window
        let maxAvailableHeight = constraintRect.maxY - anchorPoint.y - margin * 2
        let height = min(contentHeight(), Self.maxPanelHeight, max(maxAvailableHeight, Self.emptyHeight + Self.verticalInset * 2))

        let maxX = constraintRect.maxX - panelWidth - margin
        let x = min(max(anchorPoint.x, constraintRect.minX + margin), maxX)
        let maxY = constraintRect.maxY - height - margin
        let y = min(max(anchorPoint.y, constraintRect.minY + margin), maxY)
        setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: true)
    }
}

// MARK: - Row View

private final class ChatCompletionRowView: NSView {
    private let onHover: () -> Void
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?

    init(item: ChatCompletionItem, onHover: @escaping () -> Void, onClick: @escaping () -> Void) {
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ChatCompletionPanel.rowHeight).isActive = true
        toolTip = item.description

        let iconShell = NSView()
        iconShell.wantsLayer = true
        iconShell.layer?.backgroundColor = NSColor.clear.cgColor
        iconShell.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(frame: .zero)
        if let img = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.label) {
            icon.image = img.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            icon.contentTintColor = item.completionTint
        }
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: item.displayLabel)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = item.completionTint
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let desc = NSTextField(labelWithString: item.description)
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.translatesAutoresizingMaskIntoConstraints = false
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconShell)
        iconShell.addSubview(icon)
        addSubview(label)
        addSubview(desc)

        NSLayoutConstraint.activate([
            iconShell.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconShell.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconShell.widthAnchor.constraint(equalToConstant: 20),
            iconShell.heightAnchor.constraint(equalToConstant: 20),

            icon.centerXAnchor.constraint(equalTo: iconShell.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconShell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: iconShell.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            desc.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            desc.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on
            ? NSColor.labelColor.withAlphaComponent(0.065).cgColor
            : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}

// MARK: - Header / Empty Views

private final class ChatCompletionSectionHeaderView: NSView {
    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ChatCompletionPanel.headerHeight).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class ChatCompletionEmptyView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ChatCompletionPanel.emptyHeight).isActive = true

        let label = NSTextField(labelWithString: "No matches")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class CompletionDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private extension ChatCompletionItem {
    var completionTint: NSColor {
        switch kind {
        case .installedSkill:
            return NSColor.controlAccentColor
                .blended(withFraction: 0.5, of: .tertiaryLabelColor) ?? .controlAccentColor
        case .libraryReference:
            return .systemOrange
        case .noteReference:
            return .systemGreen
        }
    }
}
