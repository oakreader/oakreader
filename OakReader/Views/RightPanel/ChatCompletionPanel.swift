import AppKit

/// A floating, sectioned completion panel for `/` commands and `@` mentions.
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

    private let anchorPoint: NSPoint
    private let panelWidth: CGFloat

    fileprivate static let rowHeight: CGFloat = 34
    fileprivate static let headerHeight: CGFloat = 28
    fileprivate static let emptyHeight: CGFloat = 46
    private static let maxPanelHeight: CGFloat = 360
    private static let minPanelWidth: CGFloat = 300
    private static let maxPanelWidth: CGFloat = 680
    private static let horizontalInset: CGFloat = 16
    private static let verticalInset: CGFloat = 8

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
        onSelect: @escaping (ChatCompletionItem) -> Void
    ) {
        self.allItems = items
        self.filtered = items
        self.anchorPoint = screenPoint
        self.panelWidth = min(max(requestedWidth, Self.minPanelWidth), Self.maxPanelWidth)
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
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
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
        filtered = query.isEmpty ? allItems : allItems.filter { $0.matches(query: query) }
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
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews = []

        if filtered.isEmpty {
            let empty = ChatCompletionEmptyView()
            stackView.addArrangedSubview(empty)
            empty.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            empty.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            updateDocumentHeight()
            return
        }

        for section in sectionedItems {
            let header = ChatCompletionSectionHeaderView(title: section.title)
            stackView.addArrangedSubview(header)
            header.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            header.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true

            for item in section.items {
                let row = ChatCompletionRowView(
                    item: item,
                    onHover: { [weak self] in
                        guard let self, let index = self.filtered.firstIndex(of: item) else { return }
                        self.selectedIndex = index
                        self.updateSelection()
                    },
                    onClick: { [weak self] in self?.onSelect(item) }
                )
                stackView.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
                rowViews.append(row)
            }
        }

        updateDocumentHeight()
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
        let height = min(contentHeight(), Self.maxPanelHeight)
        let visibleFrame = NSScreen.screens
            .first { $0.visibleFrame.contains(anchorPoint) }?
            .visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 8
        let maxX = visibleFrame.maxX - panelWidth - margin
        let x = min(max(anchorPoint.x, visibleFrame.minX + margin), maxX)
        let maxY = visibleFrame.maxY - height - margin
        let y = min(max(anchorPoint.y, visibleFrame.minY + margin), maxY)
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
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ChatCompletionPanel.rowHeight).isActive = true
        toolTip = item.description

        let iconShell = NSView()
        iconShell.wantsLayer = true
        iconShell.layer?.backgroundColor = NSColor.clear.cgColor
        iconShell.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(frame: .zero)
        if let imagePath = item.imagePath,
           let img = NSImage(contentsOfFile: imagePath) {
            icon.image = img
            icon.imageScaling = .scaleProportionallyUpOrDown
            iconShell.layer?.cornerRadius = 14
            iconShell.layer?.masksToBounds = true
        } else if let img = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.label) {
            icon.image = img.withSymbolConfiguration(.init(pointSize: 19, weight: .regular))
            icon.contentTintColor = item.completionTint
        }
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: item.displayLabel)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let desc = NSTextField(labelWithString: item.description)
        desc.font = .systemFont(ofSize: 13)
        desc.textColor = .secondaryLabelColor
        desc.lineBreakMode = .byTruncatingTail
        desc.translatesAutoresizingMaskIntoConstraints = false
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconShell)
        iconShell.addSubview(icon)
        addSubview(label)
        addSubview(desc)

        NSLayoutConstraint.activate([
            iconShell.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconShell.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconShell.widthAnchor.constraint(equalToConstant: 28),
            iconShell.heightAnchor.constraint(equalToConstant: 28),

            icon.centerXAnchor.constraint(equalTo: iconShell.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconShell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: item.imagePath == nil ? 22 : 28),
            icon.heightAnchor.constraint(equalToConstant: item.imagePath == nil ? 22 : 28),

            label.leadingAnchor.constraint(equalTo: iconShell.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            desc.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            desc.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
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
        label.font = .systemFont(ofSize: 13, weight: .regular)
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
            return .controlAccentColor
        case .contextMention:
            return .systemBlue
        case .characterAgent:
            return .systemPurple
        }
    }
}
