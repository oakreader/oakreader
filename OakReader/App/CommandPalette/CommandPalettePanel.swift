import AppKit

// MARK: - Delegate

protocol CommandPalettePanelDelegate: AnyObject {
    func commandPaletteSearchChanged(_ panel: CommandPalettePanel, text: String)
    func commandPaletteDidActivate(_ panel: CommandPalettePanel, at index: Int)
    func commandPaletteDidDismiss(_ panel: CommandPalettePanel)
}

// MARK: - Panel

final class CommandPalettePanel: NSPanel, NSTextFieldDelegate {

    weak var paletteDelegate: CommandPalettePanelDelegate?

    // UI
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let separatorLine = SeparatorLineView()
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()
    private let glassContainer: NSView

    // State
    private var selectedIndex = 0
    private var rowCount = 0
    private var clickMonitor: Any?

    // Layout constants
    private static let panelWidth: CGFloat = 560
    private static let searchHeight: CGFloat = 48
    private static let rowHeight: CGFloat = 36
    private static let maxRows = 8
    private static let cornerRadius: CGFloat = 14

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Init

    init() {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glassContainer = glass
        } else {
            let vev = NSVisualEffectView()
            vev.material = .popover
            vev.state = .active
            vev.wantsLayer = true
            vev.layer?.cornerRadius = Self.cornerRadius
            vev.layer?.masksToBounds = true
            glassContainer = vev
        }

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.searchHeight),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        buildLayout()
    }

    // MARK: - Layout

    private func buildLayout() {
        // Search icon
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .tertiaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        // Search field
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 16, weight: .regular)
        searchField.textColor = .labelColor
        searchField.placeholderString = "Type a command\u{2026}"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // Separator
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        separatorLine.isHidden = true

        // List stack
        listStack.orientation = .vertical
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true

        // Content view
        let root = NSView()
        root.wantsLayer = true
        contentView = root

        glassContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(glassContainer)
        glassContainer.addSubview(searchIcon)
        glassContainer.addSubview(searchField)
        glassContainer.addSubview(separatorLine)
        glassContainer.addSubview(scrollView)

        NSLayoutConstraint.activate([
            // Glass fills content view
            glassContainer.topAnchor.constraint(equalTo: root.topAnchor),
            glassContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            glassContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glassContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            // Search icon
            searchIcon.leadingAnchor.constraint(equalTo: glassContainer.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: glassContainer.topAnchor, constant: Self.searchHeight / 2),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),

            // Search field
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: glassContainer.trailingAnchor, constant: -16),
            searchField.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),

            // Separator
            separatorLine.topAnchor.constraint(equalTo: glassContainer.topAnchor, constant: Self.searchHeight),
            separatorLine.leadingAnchor.constraint(equalTo: glassContainer.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: glassContainer.trailingAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 0.5),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: separatorLine.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: glassContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: glassContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: glassContainer.bottomAnchor),

            // List width matches scroll clip view
            listStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    // MARK: - Present / Dismiss

    func present(relativeTo parentWindow: NSWindow) {
        searchField.stringValue = ""
        selectedIndex = 0

        let parentFrame = parentWindow.frame
        let x = parentFrame.midX - Self.panelWidth / 2
        let panelH = frame.height
        let y = parentFrame.maxY - panelH - 80

        setFrame(NSRect(x: x, y: y, width: Self.panelWidth, height: panelH), display: true)
        parentWindow.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self { self.dismiss() }
            return event
        }
    }

    func dismiss() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        parent?.removeChildWindow(self)
        orderOut(nil)
        paletteDelegate?.commandPaletteDidDismiss(self)
    }

    // MARK: - Update Rows

    func updateRows(_ commands: [PaletteCommand]) {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowCount = commands.count

        for (i, cmd) in commands.enumerated() {
            let row = CommandPaletteRowView()
            row.configure(with: cmd)
            row.translatesAutoresizingMaskIntoConstraints = false

            let idx = i
            row.onClick = { [weak self] in
                guard let self else { return }
                self.paletteDelegate?.commandPaletteDidActivate(self, at: idx)
            }
            row.onHover = { [weak self] in
                guard let self else { return }
                self.selectedIndex = idx
                self.refreshSelection()
            }

            listStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
                row.leadingAnchor.constraint(equalTo: listStack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: listStack.trailingAnchor),
            ])
        }

        selectedIndex = rowCount > 0 ? 0 : -1
        refreshSelection()

        let hasResults = rowCount > 0
        separatorLine.isHidden = !hasResults
        scrollView.isHidden = !hasResults

        let visibleRows = CGFloat(min(rowCount, Self.maxRows))
        let resultH = visibleRows * Self.rowHeight + 8
        let totalH = Self.searchHeight + (hasResults ? 0.5 + resultH : 0)

        var f = frame
        let dy = f.height - totalH
        f.size.height = totalH
        f.origin.y += dy
        setFrame(f, display: true)
    }

    // MARK: - Selection

    private func refreshSelection() {
        for (i, v) in listStack.arrangedSubviews.enumerated() {
            (v as? CommandPaletteRowView)?.setSelected(i == selectedIndex)
        }
    }

    private func moveSelection(down: Bool) {
        guard rowCount > 0 else { return }
        selectedIndex = down
            ? min(selectedIndex + 1, rowCount - 1)
            : max(selectedIndex - 1, 0)
        refreshSelection()

        if selectedIndex >= 0, selectedIndex < listStack.arrangedSubviews.count {
            let row = listStack.arrangedSubviews[selectedIndex]
            scrollView.contentView.scrollToVisible(row.frame)
        }
    }

    private func activateSelection() {
        guard selectedIndex >= 0, selectedIndex < rowCount else { return }
        paletteDelegate?.commandPaletteDidActivate(self, at: selectedIndex)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        paletteDelegate?.commandPaletteSearchChanged(self, text: searchField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(moveDown(_:)) {
            moveSelection(down: true); return true
        }
        if commandSelector == #selector(moveUp(_:)) {
            moveSelection(down: false); return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            activateSelection(); return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            dismiss(); return true
        }
        return false
    }
}

// MARK: - Separator Line (appearance-adaptive)

private final class SeparatorLineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        dirtyRect.fill()
    }
}
