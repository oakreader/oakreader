import SwiftUI
import AppKit

/// NSTextView wrapper for plain-text markdown editing.
/// Uses MiaoYan's paragraph style (min/max line height + lineSpacing)
/// with a custom drawInsertionPoint to keep the cursor properly sized.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var lineHeight: CGFloat
    var lineSpacing: CGFloat
    var letterSpacing: CGFloat
    var accentColorHex: String
    var onReferenceClick: ((String) -> Void)?
    var onImagePaste: ((Data) -> String?)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = MarkdownNSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        // Force TextKit 1 so drawInsertionPoint override is called.
        // TextKit 2 (macOS 14+) uses NSTextInsertionIndicator which ignores the override.
        _ = textView.layoutManager
        textView.delegate = context.coordinator
        textView.onReferenceClick = onReferenceClick
        textView.onImagePaste = onImagePaste

        let ps = Self.paragraphStyle(font: font, lineHeight: lineHeight, lineSpacing: lineSpacing)
        textView.defaultParagraphStyle = ps
        textView.font = font
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: ps,
            .kern: letterSpacing,
        ]

        // Attach syntax highlighter
        let highlighter = MarkdownHighlighter(
            baseFont: font, lineHeight: lineHeight,
            lineSpacing: lineSpacing, letterSpacing: letterSpacing
        )
        textView.textStorage?.delegate = highlighter
        context.coordinator.highlighter = highlighter

        scrollView.documentView = textView
        context.coordinator.textView = textView

        textView.string = text
        context.coordinator.lastKnownText = text

        DispatchQueue.main.async {
            highlighter.highlightAll(in: textView.textStorage!)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownNSTextView else { return }
        let coordinator = context.coordinator

        // Check if accent color changed
        let currentAccent = coordinator.highlighter?.accentColor.hexString
        if currentAccent != accentColorHex,
           let newColor = NSColor(hex: accentColorHex) {
            coordinator.highlighter?.accentColor = newColor
            coordinator.highlighter?.highlightAll(in: textView.textStorage!)
        }

        let needsUpdate = textView.font != font
            || coordinator.highlighter?.lineSpacing != lineSpacing
            || coordinator.highlighter?.lineHeight != lineHeight
        if needsUpdate {
            let ps = Self.paragraphStyle(font: font, lineHeight: lineHeight, lineSpacing: lineSpacing)
            textView.font = font
            textView.defaultParagraphStyle = ps
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: ps,
                .kern: letterSpacing,
            ]
            coordinator.highlighter?.baseFont = font
            coordinator.highlighter?.lineHeight = lineHeight
            coordinator.highlighter?.lineSpacing = lineSpacing
            coordinator.highlighter?.letterSpacing = letterSpacing
            coordinator.highlighter?.highlightAll(in: textView.textStorage!)
        }

        if text != coordinator.lastKnownText && !coordinator.isUpdating {
            coordinator.isUpdating = true
            textView.string = text
            coordinator.lastKnownText = text
            coordinator.highlighter?.highlightAll(in: textView.textStorage!)
            coordinator.isUpdating = false
        }

        textView.onReferenceClick = onReferenceClick
        textView.onImagePaste = onImagePaste
    }

    /// TextKit 2 compatible paragraph style: lineSpacing only.
    /// No min/max line height — cursor naturally matches font height.
    /// lineHeight multiplier controls lineSpacing: (multiplier - 1) * fontSize + extra spacing.
    static func paragraphStyle(font: NSFont, lineHeight: CGFloat, lineSpacing: CGFloat) -> NSMutableParagraphStyle {
        let ps = NSMutableParagraphStyle()
        // Convert lineHeight multiplier into point-based spacing:
        // e.g. font 16pt, multiplier 1.3 → extra = 0.3 * 16 + 3 = 7.8pt between lines
        ps.lineSpacing = (lineHeight - 1.0) * font.pointSize + lineSpacing
        ps.alignment = .left
        return ps
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: MarkdownNSTextView?
        var highlighter: MarkdownHighlighter?
        var isUpdating = false
        var lastKnownText: String = ""

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            isUpdating = true
            lastKnownText = textView.string
            parent.text = textView.string
            isUpdating = false
        }

        func insertAtCursor(_ string: String) {
            guard let textView else { return }
            textView.insertText(string, replacementRange: textView.selectedRange())
        }
    }
}

// MARK: - Custom NSTextView Subclass

final class MarkdownNSTextView: NSTextView {
    var onReferenceClick: ((String) -> Void)?
    var onImagePaste: ((Data) -> String?)?

    /// Slash-command state
    private var slashPanel: SlashCommandPanel?
    private var slashStartLocation: Int?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let cursorWidth: CGFloat = 2

    /// Clamp cursor height to the font's natural height so lineSpacing never inflates it.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var r = rect
        r.size.width = Self.cursorWidth
        if let f = font ?? typingAttributes[.font] as? NSFont {
            let fontHeight = ceil(f.ascender - f.descender)
            r.size.height = min(r.size.height, fontHeight)
        }
        super.drawInsertionPoint(in: r, color: color, turnedOn: flag)
    }

    /// Tell the system the cursor rect is 2px wide so invalidation covers the full area.
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = invalidRect
        if r.size.width > 0, r.size.width < Self.cursorWidth {
            r.size.width = Self.cursorWidth
        }
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general

        // Check for image data on the pasteboard
        if let imageData = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            let pngData: Data
            if pb.data(forType: .png) != nil {
                pngData = imageData
            } else if let image = NSImage(data: imageData), let rep = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: rep),
                      let converted = bitmap.representation(using: .png, properties: [:]) {
                pngData = converted
            } else {
                super.paste(sender)
                return
            }
            if let relativePath = onImagePaste?(pngData) {
                insertText("![paste](\(relativePath))", replacementRange: selectedRange())
            }
            return
        }

        // Check for image file URLs on the pasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp"]
            if let url = urls.first, imageExts.contains(url.pathExtension.lowercased()),
               let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.lowercased()
                // Convert non-PNG formats to PNG for consistency, or pass through
                if let relativePath = onImagePaste?(data) {
                    let name = url.deletingPathExtension().lastPathComponent
                    insertText("![\(name)](\(relativePath))", replacementRange: selectedRange())
                }
                return
            }
        }

        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let hasCommand = event.modifierFlags.contains(.command)

        if hasCommand {
            switch event.charactersIgnoringModifiers {
            case "b": wrapSelection(prefix: "**", suffix: "**"); return
            case "i": wrapSelection(prefix: "*", suffix: "*"); return
            case "k": wrapSelectionAsLink(); return
            default: break
            }
        }

        // Slash panel active → intercept keys
        if slashPanel != nil {
            if handleSlashKey(event) { return }
        }

        // Start slash command mode
        if event.characters == "/" && isAtLineStart() {
            slashStartLocation = selectedRange().location
            super.keyDown(with: event)
            showSlashPanel()
            return
        }

        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        dismissSlashPanel()
        if event.clickCount == 1 {
            let point = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: point)
            if idx < string.count, let ref = extractReference(at: idx) {
                onReferenceClick?(ref)
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: - Markdown Shortcuts

    private func wrapSelection(prefix: String, suffix: String) {
        let range = selectedRange()
        guard range.length > 0 else {
            insertText("\(prefix)\(suffix)", replacementRange: range)
            setSelectedRange(NSRange(location: range.location + prefix.count, length: 0))
            return
        }
        let selected = (string as NSString).substring(with: range)
        insertText("\(prefix)\(selected)\(suffix)", replacementRange: range)
        setSelectedRange(NSRange(location: range.location + prefix.count, length: range.length))
    }

    private func wrapSelectionAsLink() {
        let range = selectedRange()
        let selected = range.length > 0 ? (string as NSString).substring(with: range) : ""
        let pb = NSPasteboard.general.string(forType: .string) ?? ""
        let isURL = pb.hasPrefix("http://") || pb.hasPrefix("https://")

        if isURL && !selected.isEmpty {
            insertText("[\(selected)](\(pb))", replacementRange: range)
        } else {
            insertText("[\(selected)](url)", replacementRange: range)
            setSelectedRange(NSRange(location: range.location + selected.count + 3, length: 3))
        }
    }

    // MARK: - Slash Command (Notion-style)

    private func isAtLineStart() -> Bool {
        let loc = selectedRange().location
        guard loc > 0 else { return true }
        return (string as NSString).character(at: loc - 1) == 0x0A
    }

    private func showSlashPanel() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let glyphRange = lm.glyphRange(forCharacterRange: selectedRange(), actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let origin = NSPoint(
            x: rect.origin.x + textContainerInset.width,
            y: rect.origin.y + textContainerInset.height + rect.height + 4
        )
        let viewPt = convert(origin, to: nil)
        guard let screenPt = window?.convertPoint(toScreen: viewPt) else { return }

        slashPanel = SlashCommandPanel(at: screenPt) { [weak self] cmd in
            self?.executeSlashCommand(cmd)
        }
    }

    private func dismissSlashPanel() {
        slashPanel?.dismiss()
        slashPanel = nil
        slashStartLocation = nil
    }

    private func handleSlashKey(_ event: NSEvent) -> Bool {
        guard slashPanel != nil, let startLoc = slashStartLocation else { return false }

        switch event.keyCode {
        case 53: dismissSlashPanel(); return true                         // Escape
        case 36:                                                          // Enter
            if let cmd = slashPanel?.selectedCommand { executeSlashCommand(cmd) }
            else { dismissSlashPanel() }
            return true
        case 126: slashPanel?.moveSelection(by: -1); return true          // Up
        case 125: slashPanel?.moveSelection(by: 1); return true           // Down
        case 51:                                                          // Backspace
            if selectedRange().location <= startLoc {
                dismissSlashPanel(); super.keyDown(with: event); return true
            }
            super.keyDown(with: event); updateSlashFilter(); return true
        default:
            if let c = event.characters, !c.isEmpty {
                if c == " " { dismissSlashPanel(); super.keyDown(with: event); return true }
                super.keyDown(with: event); updateSlashFilter(); return true
            }
            return false
        }
    }

    private func updateSlashFilter() {
        guard let panel = slashPanel, let startLoc = slashStartLocation else { return }
        let cur = selectedRange().location
        let filterStart = startLoc + 1
        guard filterStart <= cur else { dismissSlashPanel(); return }
        let query = (string as NSString).substring(with: NSRange(location: filterStart, length: cur - filterStart))
        panel.filter(query: query.lowercased())
        if panel.filteredCount == 0 { dismissSlashPanel() }
    }

    private func executeSlashCommand(_ cmd: SlashCommandPanel.Command) {
        guard let startLoc = slashStartLocation else { return }
        dismissSlashPanel()
        let deleteRange = NSRange(location: startLoc, length: selectedRange().location - startLoc)
        insertText("", replacementRange: deleteRange)
        let loc = selectedRange().location
        insertText(cmd.text, replacementRange: selectedRange())
        if cmd.cursorBack > 0 {
            setSelectedRange(NSRange(location: loc + cmd.text.count - cmd.cursorBack, length: 0))
        }
    }

    // MARK: - Reference Extraction

    private func extractReference(at index: Int) -> String? {
        let ns = string as NSString
        let len = ns.length
        guard index < len else { return nil }

        var start = index
        while start > 0 {
            if start + 1 < len, ns.character(at: start) == 0x5B, ns.character(at: start + 1) == 0x5B { break }
            if ns.character(at: start) == 0x0A { return nil }
            start -= 1
        }
        var end = index
        while end < len - 1 {
            if ns.character(at: end) == 0x5D, ns.character(at: end + 1) == 0x5D {
                let r = NSRange(location: start, length: end + 2 - start)
                return ns.substring(with: r).replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            }
            if ns.character(at: end) == 0x0A { return nil }
            end += 1
        }
        return nil
    }
}

// MARK: - Slash Command Panel

final class SlashCommandPanel: NSPanel {

    struct Command {
        let icon: String
        let label: String
        let keywords: [String]
        let text: String
        let cursorBack: Int
    }

    static let allCommands: [Command] = [
        .init(icon: "textformat.size.larger", label: "Heading 1", keywords: ["h1", "heading1", "title"], text: "# ", cursorBack: 0),
        .init(icon: "textformat.size", label: "Heading 2", keywords: ["h2", "heading2"], text: "## ", cursorBack: 0),
        .init(icon: "textformat.size.smaller", label: "Heading 3", keywords: ["h3", "heading3"], text: "### ", cursorBack: 0),
        .init(icon: "list.bullet", label: "Bullet List", keywords: ["bullet", "ul", "list"], text: "- ", cursorBack: 0),
        .init(icon: "list.number", label: "Numbered List", keywords: ["number", "ol", "ordered"], text: "1. ", cursorBack: 0),
        .init(icon: "checklist", label: "Task List", keywords: ["task", "todo", "check"], text: "- [ ] ", cursorBack: 0),
        .init(icon: "text.quote", label: "Quote", keywords: ["quote", "blockquote", "bq"], text: "> ", cursorBack: 0),
        .init(icon: "chevron.left.forwardslash.chevron.right", label: "Code Block", keywords: ["code", "fence"], text: "```\n\n```", cursorBack: 4),
        .init(icon: "minus", label: "Divider", keywords: ["divider", "hr", "line"], text: "---\n", cursorBack: 0),
        .init(icon: "link", label: "Link", keywords: ["link", "url", "href"], text: "[](url)", cursorBack: 6),
        .init(icon: "photo", label: "Image", keywords: ["image", "img", "photo"], text: "![alt](url)", cursorBack: 4),
        .init(icon: "tablecells", label: "Table", keywords: ["table"], text: "| Col 1 | Col 2 |\n| --- | --- |\n| | |", cursorBack: 3),
        .init(icon: "bold", label: "Bold", keywords: ["bold", "strong", "b"], text: "****", cursorBack: 2),
        .init(icon: "italic", label: "Italic", keywords: ["italic", "em", "i"], text: "**", cursorBack: 1),
        .init(icon: "strikethrough", label: "Strikethrough", keywords: ["strike", "del", "s"], text: "~~~~", cursorBack: 2),
        .init(icon: "chevron.left.forwardslash.chevron.right", label: "Inline Code", keywords: ["inline", "icode"], text: "``", cursorBack: 1),
    ]

    private var filtered: [Command] = allCommands
    private var selectedIndex = 0
    private var rowViews: [SlashRowView] = []
    private let stackView = NSStackView()
    private let onSelect: (Command) -> Void

    var selectedCommand: Command? {
        guard selectedIndex >= 0, selectedIndex < filtered.count else { return nil }
        return filtered[selectedIndex]
    }

    var filteredCount: Int { filtered.count }

    init(at screenPoint: NSPoint, onSelect: @escaping (Command) -> Void) {
        self.onSelect = onSelect
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = true

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8

        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        bg.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: bg.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stackView.widthAnchor.constraint(equalToConstant: 220),
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = bg
        contentView = scroll

        buildRows()
        updateSelection()
        sizeAndPosition(at: screenPoint)

        orderFront(nil)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; self.animator().alphaValue = 1 }
    }

    func filter(query: String) {
        filtered = query.isEmpty ? Self.allCommands : Self.allCommands.filter { cmd in
            cmd.label.lowercased().contains(query) || cmd.keywords.contains { $0.hasPrefix(query) }
        }
        selectedIndex = 0
        buildRows()
        updateSelection()
        let origin = frame.origin
        sizeAndPosition(at: NSPoint(x: origin.x, y: origin.y + frame.height))
    }

    func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + filtered.count) % filtered.count
        updateSelection()
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.08; self.animator().alphaValue = 0 },
                                            completionHandler: { self.orderOut(nil) })
    }

    private func buildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = filtered.map { cmd in
            let row = SlashRowView(command: cmd) { [weak self] in self?.onSelect(cmd) }
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            return row
        }
    }

    private func updateSelection() {
        for (i, row) in rowViews.enumerated() { row.setHighlighted(i == selectedIndex) }
        if selectedIndex < rowViews.count { rowViews[selectedIndex].scrollToVisible(rowViews[selectedIndex].bounds) }
    }

    private func sizeAndPosition(at topPt: NSPoint) {
        let h = CGFloat(min(filtered.count, 8)) * 30 + 8
        setFrame(NSRect(x: topPt.x, y: topPt.y - h, width: 220, height: h), display: true)
    }
}

// MARK: - Slash Row View

private final class SlashRowView: NSView {
    private let onClick: () -> Void
    private var trackingArea: NSTrackingArea?

    init(command: SlashCommandPanel.Command, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        let icon = NSImageView(frame: .zero)
        if let img = NSImage(systemSymbolName: command.icon, accessibilityDescription: command.label) {
            icon.image = img.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        }
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: command.label)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : nil
        layer?.cornerRadius = 4
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
