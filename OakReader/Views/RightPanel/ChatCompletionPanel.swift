import AppKit

// The dropdown's colours + metrics now live in the shared `CompletionPalette`
// (`CompletionPalette.swift`) so this AppKit panel and the SwiftUI note `@`/`#`
// pickers render pixel-identically from one source.

/// A floating, sectioned completion panel for `/` commands and `@` references.
/// The panel intentionally mirrors the chat composer width so the trigger UI
/// feels connected to the input instead of appearing as a detached menu.
///
/// Visuals are a faithful reproduction of Dia 1.36's command-bar suggestion panel,
/// measured from a live screenshot (NOT guessed from asset tokens):
///   • Card: white `#FFFFFF` / dark `#141415`, 14pt continuous corners, hairline
///     border, soft drop shadow.
///   • Row: 28pt tall, 16pt glyph shown directly (NO grey tile), 12pt left pad,
///     8pt icon→title gap, 13.5pt title.
///   • Selection: accent-blue pill (`#6A9FF9` / `#2B57B7`) with WHITE text/icon,
///     8pt corners, 6pt horizontal inset from the card edge.
///   • Header: UPPERCASE 11pt semibold grey (`#BEBEBE`) tracked ~0.5, left-aligned
///     to the icon column.
final class ChatCompletionPanel: NSPanel, AppResignDismissable {

    var resignObserver: NSObjectProtocol?

    private let palette: CompletionPalette
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
    private lazy var emptyView = ChatCompletionEmptyView(palette: palette)

    /// The composer's frame in screen coordinates. The panel mirrors its width and
    /// floats just above it (falling back to below when there's no room above).
    private let anchorRect: NSRect
    /// The visible frame of the screen the composer lives on (from `window.screen`),
    /// so clamping never targets the wrong display on a multi-monitor setup.
    private let screenVisibleFrame: NSRect
    private let panelWidth: CGFloat

    // Row metrics come from the shared `CompletionPalette.Metrics` so this panel and
    // the SwiftUI note pickers measure to the same pixels.
    fileprivate static let rowHeight = CompletionPalette.Metrics.rowHeight
    fileprivate static let headerHeight = CompletionPalette.Metrics.headerHeight
    fileprivate static let emptyHeight: CGFloat = 44
    // ~9 rows tall, then scroll. Keeps the popup compact instead of ballooning to
    // fill the pane when a trigger (e.g. `@`) surfaces dozens of items.
    private static let maxPanelHeight: CGFloat = 320
    private static let minPanelWidth: CGFloat = 260
    // Mirrors the chat composer width but capped tight — the popup should read as a
    // compact suggestion menu (Dia's is ~260pt), never a pane-wide sheet.
    private static let maxPanelWidth: CGFloat = 320
    // Card content inset. The selection pill fills the full stack width, so this
    // doubles as the selection's 6pt horizontal inset from the card edge (measured).
    private static let horizontalInset = CompletionPalette.Metrics.horizontalInset
    private static let verticalInset = CompletionPalette.Metrics.verticalInset
    private static let cornerRadius = CompletionPalette.Metrics.cornerRadius

    var selectedItem: ChatCompletionItem? {
        guard selectedIndex >= 0, selectedIndex < filtered.count else { return nil }
        return filtered[selectedIndex]
    }

    var filteredCount: Int { filtered.count }

    // MARK: - Init

    init(
        items: [ChatCompletionItem],
        anchorRect: NSRect,
        screenVisibleFrame: NSRect,
        onSelect: @escaping (ChatCompletionItem) -> Void
    ) {
        self.allItems = items
        self.filtered = items
        self.anchorRect = anchorRect
        self.screenVisibleFrame = screenVisibleFrame
        self.panelWidth = min(max(anchorRect.width, Self.minPanelWidth), Self.maxPanelWidth)
        self.onSelect = onSelect
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.palette = CompletionPalette(isDark: isDark)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isOpaque = false
        backgroundColor = .clear
        level = .floating
        // A soft, rounded drop shadow (matched to the corner radius below) lifts the
        // popup off the composer the way Dia's suggestion panel does.
        hasShadow = true
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

        // Dia's suggestion panel (`ARCUI.PopoverBackgroundView`) reads as a clean NEUTRAL
        // card — white in light, a deep near-black `#161617` in dark. We render it as a
        // SOLID opaque surface (not a `.behindWindow` vibrant material): the panel floats
        // over the chat pane's own rounded cards, and a translucent frost let those show
        // through — the "a background behind the background" artifact. Opaque kills that
        // and also keeps the card from reading grey.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = palette.panelBackground.cgColor
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = palette.border.cgColor
        container.layer?.cornerCurve = .continuous
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
        // Re-assert the frame AFTER ordering. `orderFront` relocates a window onto the
        // active screen on first display (the real cause of the "flying off" on a
        // secondary monitor); setting the frame again here pins it where we want. This
        // single line is what actually holds the position — do not remove it.
        sizeAndPosition()
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            self.animator().alphaValue = 1
        }
    }

    deinit {
        removeAppResignObserver()
    }

    /// Neutralise AppKit's automatic window constraining. The default keeps a window's
    /// title bar below the menu bar and on its screen, which — for a positioned,
    /// borderless popup on a secondary display with a negative-origin coordinate space —
    /// quietly relocates the panel ("flies off"). We position it ourselves.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // MARK: - Filtering

    /// Replace the panel's items wholesale (the note `#` picker rebuilds its list as
    /// you type so a live "Create #tag" row can appear/disappear — `filter` can only
    /// narrow a fixed list, never add a row that reflects the typed text).
    func setItems(_ items: [ChatCompletionItem]) {
        allItems = items
        filtered = items
        selectedIndex = items.isEmpty ? -1 : 0
        buildRows()
        updateSelection()
        sizeAndPosition()
    }

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
                let h = ChatCompletionSectionHeaderView(title: section.title, palette: palette)
                cachedHeaders[section.title] = h
                return h
            }()
            stackView.addArrangedSubview(header)
            pin(header)

            for item in section.items {
                let row = cachedRows[item.id] ?? {
                    let r = ChatCompletionRowView(
                        item: item,
                        palette: palette,
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
        // Clamp against the composer window's frame (∩ its screen) — so the popup stays
        // inside the chat pane and never spills past its right edge or onto another display.
        let visible = screenVisibleFrame
        let margin: CGFloat = 8
        let gap: CGFloat = 8

        // Width never exceeds the composer's own span (the chat pane) — so the popup
        // can't spill past the pane's right edge into the document — nor the screen.
        let width = min(panelWidth, min(anchorRect.width, visible.width - margin * 2))

        // Horizontal: mirror the composer's left edge, kept inside the pane and screen.
        let rightBound = min(visible.maxX - margin, anchorRect.maxX)
        let x = min(max(anchorRect.minX, visible.minX + margin), rightBound - width)

        // Vertical: prefer floating above the composer; fall back to below when the
        // space above is too tight (e.g. composer dragged near the top of the screen).
        let desired = min(contentHeight(), Self.maxPanelHeight)
        let spaceAbove = visible.maxY - anchorRect.maxY - gap - margin
        let spaceBelow = anchorRect.minY - visible.minY - gap - margin

        let height: CGFloat
        let y: CGFloat
        if desired <= spaceAbove || spaceAbove >= spaceBelow {
            height = max(min(desired, spaceAbove), Self.emptyHeight + Self.verticalInset * 2)
            y = anchorRect.maxY + gap                 // panel bottom sits above the composer top
        } else {
            height = max(min(desired, spaceBelow), Self.emptyHeight + Self.verticalInset * 2)
            y = anchorRect.minY - gap - height        // panel top sits below the composer bottom
        }
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

// MARK: - Row View

private final class ChatCompletionRowView: NSView {
    private let palette: CompletionPalette
    private let item: ChatCompletionItem
    private let titleLabel: NSTextField
    private let descLabel: NSTextField
    private let iconView: NSImageView
    private let onHover: () -> Void
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?
    private var isHighlighted = false

    // Glyph shown directly (no tile), 12pt from the card edge. The card content
    // already insets 6pt, so the icon adds the remaining 6pt here. Sourced from the
    // shared `CompletionPalette.Metrics` so the note pickers match.
    private static let iconSize = CompletionPalette.Metrics.iconFrame
    private static let iconLeading = CompletionPalette.Metrics.iconLeading
    private static let iconToTitle = CompletionPalette.Metrics.iconToTitle
    private static let selectionRadius = CompletionPalette.Metrics.selectionRadius

    init(
        item: ChatCompletionItem,
        palette: CompletionPalette,
        onHover: @escaping () -> Void,
        onClick: @escaping () -> Void
    ) {
        self.palette = palette
        self.item = item
        self.titleLabel = NSTextField(labelWithString: item.displayLabel)
        self.descLabel = NSTextField(labelWithString: item.description)
        self.iconView = NSImageView(frame: .zero)
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.selectionRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ChatCompletionPanel.rowHeight).isActive = true
        toolTip = item.description

        // Glyph shown directly — no grey tile (matches Dia's favicons/SF symbols).
        if let img = SymbolStyle.filled(item.icon, accessibilityDescription: item.label) {
            iconView.image = img.withSymbolConfiguration(.init(pointSize: CompletionPalette.Metrics.iconPointSize, weight: .medium))
            iconView.contentTintColor = item.completionTint
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: CompletionPalette.Metrics.titleSize, weight: .regular)
        titleLabel.textColor = palette.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // LOW compression resistance: a long @-mention title must TRUNCATE, never widen
        // the row. With high resistance the label refuses to shrink and AutoLayout grows
        // the panel's fitting width instead (the popup window then adopts it) — which is
        // why long document titles ballooned the panel past its width clamp.
        // BUT it must still outrank the description (just below), or a long skill
        // description (e.g. Grill/Socratic) squeezes the title to zero width and the
        // skill NAME disappears. So: title 251 > description 249 — both stay "low" so
        // neither widens the window, but the title wins the tug-of-war and the
        // description truncates first.
        // Default: title outranks description (251 > 249) so a long skill description
        // truncates before the skill name. When `pinnedDescription` is set (note
        // `@`-mentions, whose description is a short fixed date that must always show),
        // flip it — the TITLE truncates first so the date survives.
        let titlePriority: Float = item.pinnedDescription ? 249 : 251
        let descPriority: Float = item.pinnedDescription ? 251 : 249
        titleLabel.setContentCompressionResistancePriority(.init(titlePriority), for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        descLabel.font = .systemFont(ofSize: CompletionPalette.Metrics.secondarySize)
        descLabel.textColor = palette.secondary
        descLabel.alignment = .right
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.setContentCompressionResistancePriority(.init(descPriority), for: .horizontal)
        descLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(descLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconLeading),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconToTitle),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Bound the title's trailing edge so a long @-mention label (which often has
            // no right-aligned description to pin against) truncates instead of spilling
            // past the row/panel edge.
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: descLabel.leadingAnchor, constant: -10),
            descLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            descLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setHighlighted(_ on: Bool) {
        isHighlighted = on
        // Accent-blue pill with WHITE text/icon when selected (Dia parity); fully
        // transparent otherwise so the card fill shows through.
        layer?.backgroundColor = on ? palette.selectionFill.cgColor : NSColor.clear.cgColor
        titleLabel.textColor = on ? palette.onSelectionText : palette.title
        descLabel.textColor = on ? palette.onSelectionSecondary : palette.secondary
        iconView.contentTintColor = on ? palette.onSelectionText : item.completionTint
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
    init(title: String, palette: CompletionPalette) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ChatCompletionPanel.headerHeight).isActive = true

        // UPPERCASE, 11pt semibold, tracked ~0.5, grey — left-aligned to the icon column
        // (12pt from the card edge: 6pt card inset + 6pt to match the row's icon leading).
        let label = NSTextField(labelWithString: title.uppercased())
        label.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: palette.header,
                .kern: 0.5,
            ]
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class ChatCompletionEmptyView: NSView {
    init(palette: CompletionPalette) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: ChatCompletionPanel.emptyHeight).isActive = true

        let label = NSTextField(labelWithString: "No matches")
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = palette.secondary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
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
    /// Neutral monochrome glyph for every row (skills and library refs alike). Tinting
    /// each symbol its own accent/orange read as noisy; Dia keeps the icon column calm
    /// and grey, letting the selection pill be the only colour. White when selected.
    var completionTint: NSColor { .secondaryLabelColor }
}
