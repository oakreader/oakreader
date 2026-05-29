import SwiftUI

/// A multi-line text input that sends on Enter and inserts a newline on Cmd+Enter.
/// Reports its content height so the parent can size it to fit.
/// Supports `/` slash commands via inline token chips and drag-and-drop library references.
struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Ask about this Document..."
    var onSend: () -> Void
    var onPasteImage: ((Data) -> Void)?
    @Binding var contentHeight: CGFloat

    /// Items shown when the user types `/`.
    var slashItems: [ChatCompletionItem] = []
    /// Called whenever the set of active token chips changes.
    var onActiveTokensChanged: (([ChatCompletionItem]) -> Void)?

    /// Incremented by the parent to force-clear rich text attachments after send.
    var resetToken: Int = 0

    /// Body font size — aligned by the host to the surrounding message text so
    /// the composer (and its token chips) match the rendered "正文" size.
    var fontSize: CGFloat = 16

    static let minContentHeight: CGFloat = 40
    static let maxContentHeight: CGFloat = 180

    /// Shared reference so the parent SwiftUI view can trigger focus.
    class FocusRef {
        weak var textView: ChatNSTextView?
        func focus() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
        func insertDroppedToken(_ item: ChatCompletionItem) {
            textView?.insertDroppedToken(item)
        }
        func dismissCompletion() {
            textView?.dismissCompletionIfNeeded()
        }
    }

    let focusRef: FocusRef

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = ChatNSTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.onPasteImage = onPasteImage
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: fontSize)
        textView.tokenFontSize = fontSize
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

        textView.slashItems = slashItems
        textView.onTokensChanged = { tokens in
            context.coordinator.parent.onActiveTokensChanged?(tokens)
        }
        textView.onPlainTextChanged = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.syncTextFromTextView(textView)
        }
        textView.onCompositionChanged = { [weak coordinator = context.coordinator] in
            coordinator?.updatePlaceholder()
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        focusRef.textView = textView

        if text.isEmpty {
            textView.string = ""
            context.coordinator.updatePlaceholder()
        } else {
            textView.string = text
        }

        DispatchQueue.main.async {
            context.coordinator.updateHeight()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ChatNSTextView else { return }

        if context.coordinator.lastResetToken != resetToken {
            context.coordinator.lastResetToken = resetToken
            context.coordinator.isUpdating = true
            textView.textStorage?.setAttributedString(NSAttributedString())
            textView.string = ""
            context.coordinator.updatePlaceholder()
            context.coordinator.updateHeight()
            context.coordinator.isUpdating = false
        }

        // Sync text from SwiftUI -> NSTextView only when externally changed.
        // Check plainText to avoid fighting with tokens while the user is composing.
        let currentPlain = textView.plainText()
        if currentPlain != text && !context.coordinator.isUpdating {
            context.coordinator.isUpdating = true
            if text.isEmpty {
                // Full clear (after send): remove all tokens too
                textView.textStorage?.setAttributedString(NSAttributedString())
                textView.string = ""
            } else {
                textView.string = text
            }
            context.coordinator.updatePlaceholder()
            context.coordinator.updateHeight()
            context.coordinator.isUpdating = false
        }

        textView.onSend = onSend
        textView.onPasteImage = onPasteImage
        textView.slashItems = slashItems
        if textView.font?.pointSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
        }
        textView.tokenFontSize = fontSize
        textView.onTokensChanged = { tokens in
            context.coordinator.parent.onActiveTokensChanged?(tokens)
        }
        textView.onPlainTextChanged = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.syncTextFromTextView(textView)
        }
        textView.onCompositionChanged = { [weak coordinator = context.coordinator] in
            coordinator?.updatePlaceholder()
        }
        focusRef.textView = textView
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        weak var textView: ChatNSTextView?
        var isUpdating = false
        var lastResetToken: Int
        private var placeholderView: NSTextField?

        init(_ parent: ChatInputTextView) {
            self.parent = parent
            self.lastResetToken = parent.resetToken
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ChatNSTextView else { return }
            syncTextFromTextView(textView)
        }

        func syncTextFromTextView(_ textView: ChatNSTextView) {
            guard !isUpdating else { return }
            isUpdating = true
            parent.text = textView.plainText()
            updatePlaceholder()
            updateHeight()
            isUpdating = false
        }

        func updateHeight() {
            guard let textView else { return }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let usedRect = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
            let fittingHeight = ceil(usedRect.height + textView.textContainerInset.height * 2 + 2)
            let newHeight = min(max(fittingHeight, ChatInputTextView.minContentHeight), ChatInputTextView.maxContentHeight)
            DispatchQueue.main.async {
                guard abs(self.parent.contentHeight - newHeight) > 0.5 else { return }
                self.parent.contentHeight = newHeight
            }
        }

        func updatePlaceholder() {
            guard let textView else { return }
            let isEmpty = textView.plainText().isEmpty && textView.activeTokens().isEmpty && !textView.hasMarkedText()
            if isEmpty {
                if placeholderView == nil {
                    let label = PassthroughTextField(labelWithString: parent.placeholder)
                    label.textColor = .placeholderTextColor
                    label.font = textView.font
                    label.isEditable = false
                    label.isSelectable = false
                    label.drawsBackground = false
                    label.isBordered = false
                    label.translatesAutoresizingMaskIntoConstraints = false
                    textView.addSubview(label)
                    NSLayoutConstraint.activate([
                        label.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                        label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 4),
                    ])
                    placeholderView = label
                }
                placeholderView?.isHidden = false
            } else {
                placeholderView?.isHidden = true
            }
        }
    }
}

// MARK: - Click-through placeholder label

/// An NSTextField that ignores all mouse events so clicks pass through
/// to the NSTextView underneath.
private final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Custom NSTextView

final class ChatNSTextView: NSTextView {
    var onSend: (() -> Void)?
    var onPasteImage: ((Data) -> Void)?
    var onPlainTextChanged: (() -> Void)?
    var onCompositionChanged: (() -> Void)?

    // MARK: - Completion State

    var slashItems: [ChatCompletionItem] = []
    var onTokensChanged: (([ChatCompletionItem]) -> Void)?
    /// Font size used when rendering inserted token chips, kept in sync with the
    /// text view's body font so chips match the typed text.
    var tokenFontSize: CGFloat = 16

    private var completionPanel: ChatCompletionPanel?
    private var triggerChar: String?
    private var triggerLocation: Int?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        insertionPointColor = .labelColor
    }

    // MARK: - IME Composition

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChanged?()
    }

    // MARK: - Context Menu

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let removeTitles: Set<String> = ["Services", "Substitutions", "Transformations",
                                         "Speech", "Layout Orientation", "AutoFill",
                                         "Spelling and Grammar"]
        menu.items.removeAll { item in
            if let submenuTitle = item.submenu?.title, removeTitles.contains(submenuTitle) {
                return true
            }
            if removeTitles.contains(item.title) { return true }
            if item.title.hasPrefix("Search With") { return true }
            if item.title.contains("Unlearn Spelling") { return true }
            return false
        }

        for item in menu.items where item.image == nil {
            switch item.title {
            case "Cut":
                item.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
            case "Copy":
                item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            case "Paste":
                item.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
            case "Select All":
                item.image = NSImage(systemSymbolName: "selection.pin.in.out", accessibilityDescription: nil)
            case let t where t.hasPrefix("Look Up"):
                item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            case "Translate":
                item.image = NSImage(systemSymbolName: "translate", accessibilityDescription: nil)
            default:
                break
            }
        }

        super.willOpenMenu(menu, with: event)
    }

    // MARK: - Key Handling

    override func keyDown(with event: NSEvent) {
        // Route to completion panel if active
        if completionPanel != nil {
            if handleCompletionKey(event) { return }
        }

        let isReturn = event.keyCode == 36
        let hasCommand = event.modifierFlags.contains(.command)
        let hasShift = event.modifierFlags.contains(.shift)

        if isReturn && !hasCommand && !hasShift {
            onSend?()
            return
        }

        if isReturn && (hasCommand || hasShift) {
            insertNewline(nil)
            return
        }

        // Detect "/" trigger for slash commands
        if let chars = event.characters, chars.count == 1,
           !event.modifierFlags.contains(.command) {
            let ch = chars.first!
            if ch == "/" {
                // Only trigger at input start (no preceding text except whitespace/attachments)
                let loc = selectedRange().location
                if loc == 0 || isAtEffectiveStart(loc) {
                    if !slashItems.isEmpty && !hasSlashToken() {
                        super.keyDown(with: event)
                        showCompletionPanel(trigger: "/", items: slashItems)
                        return
                    }
                }
            }
        }

        super.keyDown(with: event)
    }

    // MARK: - Paste

    override func paste(_ sender: Any?) {
        guard let handler = onPasteImage else {
            super.paste(sender)
            return
        }

        let pb = NSPasteboard.general
        let types = pb.types ?? []

        // Any image on the pasteboard — screenshots, SnipPaste, Preview, etc.
        let hasImage = types.contains(.tiff) || types.contains(.png)
        if hasImage,
           let image = NSImage(pasteboard: pb),
           let png = image.pngData() {
            handler(png)
            return
        }

        // Image file URL pasted (e.g. from Finder)
        if types.contains(.fileURL),
           let urlString = pb.string(forType: .fileURL),
           let url = URL(string: urlString) {
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "webp"].contains(ext),
               let image = NSImage(contentsOf: url),
               let png = image.pngData() {
                handler(png)
                return
            }
        }

        super.paste(sender)
    }

    // MARK: - Completion Panel

    private func showCompletionPanel(trigger: String, items: [ChatCompletionItem]) {
        dismissCompletionPanel()

        triggerChar = trigger
        triggerLocation = selectedRange().location - 1  // before the trigger char we just inserted

        guard let anchor = popupAnchor() else { return }

        completionPanel = ChatCompletionPanel(
            items: items,
            at: anchor.point,
            width: anchor.width,
            windowFrame: anchor.windowFrame
        ) { [weak self] item in
            self?.insertToken(item)
        }

        // Attach as child so the panel moves with the main window when dragged.
        if let panel = completionPanel, let parentWindow = window {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
    }

    private func dismissCompletionPanel() {
        completionPanel?.dismiss()
        completionPanel = nil
        triggerChar = nil
        triggerLocation = nil
    }

    /// Public entry point so SwiftUI can dismiss the popup (e.g. on tab switch).
    func dismissCompletionIfNeeded() {
        if completionPanel != nil { dismissCompletionPanel() }
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard completionPanel != nil, let startLoc = triggerLocation else { return false }

        switch event.keyCode {
        case 53:  // Escape
            dismissCompletionPanel()
            return true
        case 36:  // Enter
            if let item = completionPanel?.selectedItem {
                insertToken(item)
            } else {
                dismissCompletionPanel()
            }
            return true
        case 126:  // Up
            completionPanel?.moveSelection(by: -1)
            return true
        case 125:  // Down
            completionPanel?.moveSelection(by: 1)
            return true
        case 51:  // Backspace
            if selectedRange().location <= startLoc {
                dismissCompletionPanel()
                super.keyDown(with: event)
                return true
            }
            super.keyDown(with: event)
            updateCompletionFilter()
            return true
        default:
            if let c = event.characters, !c.isEmpty {
                if c == " " {
                    super.keyDown(with: event)
                    updateCompletionFilter()
                    return true
                }
                super.keyDown(with: event)
                updateCompletionFilter()
                return true
            }
            return false
        }
    }

    private func updateCompletionFilter() {
        guard let panel = completionPanel, let startLoc = triggerLocation else { return }
        let cur = selectedRange().location
        let filterStart = startLoc + 1  // skip the trigger character
        guard filterStart <= cur else { dismissCompletionPanel(); return }
        let query = (string as NSString).substring(
            with: NSRange(location: filterStart, length: cur - filterStart)
        )
        panel.filter(query: query)
    }

    // MARK: - Token Insertion

    private func insertToken(_ item: ChatCompletionItem) {
        guard let startLoc = triggerLocation else { return }
        dismissCompletionPanel()

        // Enforce: only one slash token allowed
        if item.trigger == "/" && hasSlashToken() { return }

        // Delete the trigger text (trigger char + any filter text typed)
        let curLoc = selectedRange().location
        let deleteRange = NSRange(location: startLoc, length: curLoc - startLoc)

        insertTokenAttachment(item, replacingRange: deleteRange)
    }

    /// Insert a token from a drag-and-drop operation at the current insertion point.
    func insertDroppedToken(_ item: ChatCompletionItem) {
        // Don't insert duplicate library references
        if activeTokens().contains(where: { $0.id == item.id }) { return }

        let curLoc = selectedRange().location
        let insertRange = NSRange(location: curLoc, length: 0)
        insertTokenAttachment(item, replacingRange: insertRange)
    }

    private func insertTokenAttachment(_ item: ChatCompletionItem, replacingRange range: NSRange) {
        // Need rich text temporarily to insert attachment
        let wasRichText = isRichText
        isRichText = true

        // Build attributed string with attachment
        let attachment = ChatTokenAttachment(item: item, fontSize: tokenFontSize)
        let attachStr = NSAttributedString(attachment: attachment)

        // Insert attachment + trailing space
        let mutable = NSMutableAttributedString(attributedString: attachStr)
        let spaceAttrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: tokenFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        mutable.append(NSAttributedString(string: " ", attributes: spaceAttrs))

        textStorage?.replaceCharacters(in: range, with: mutable)
        setSelectedRange(NSRange(location: range.location + mutable.length, length: 0))

        isRichText = wasRichText

        onPlainTextChanged?()
        notifyTokensChanged()
    }

    // MARK: - Token Queries

    /// Returns all `ChatCompletionItem`s currently embedded as token attachments.
    func activeTokens() -> [ChatCompletionItem] {
        guard let storage = textStorage else { return [] }
        var tokens: [ChatCompletionItem] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let tokenAttachment = value as? ChatTokenAttachment {
                tokens.append(tokenAttachment.item)
            }
        }
        return tokens
    }

    /// Returns the plain text content, stripping attachment characters.
    func plainText() -> String {
        guard let storage = textStorage else { return string }
        var result = ""
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            if attrs[.attachment] is ChatTokenAttachment {
                // Skip attachment characters
            } else {
                result += (storage.string as NSString).substring(with: range)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a `/skill` token is already present.
    private func hasSlashToken() -> Bool {
        activeTokens().contains { $0.trigger == "/" }
    }

    /// Whether the cursor is at the effective start of input (only attachments/whitespace before).
    private func isAtEffectiveStart(_ location: Int) -> Bool {
        guard let storage = textStorage else { return location == 0 }
        let before = NSRange(location: 0, length: location)
        var onlyWhitespaceOrAttachments = true
        storage.enumerateAttributes(in: before) { attrs, range, stop in
            if attrs[.attachment] is ChatTokenAttachment { return }
            let text = (storage.string as NSString).substring(with: range)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                onlyWhitespaceOrAttachments = false
                stop.pointee = true
            }
        }
        return onlyWhitespaceOrAttachments
    }

    private func notifyTokensChanged() {
        onTokensChanged?(activeTokens())
    }

    /// Computes the screen point, width, and window frame for the completion popup.
    /// It is anchored to the input region so the popup aligns with the composer.
    private func popupAnchor() -> (point: NSPoint, width: CGFloat, windowFrame: NSRect)? {
        guard let window else { return nil }
        let sourceView: NSView = enclosingScrollView ?? self
        let inputRect = sourceView.convert(sourceView.bounds, to: nil)
        let composerHorizontalPadding: CGFloat = 14
        let composerTopPadding: CGFloat = 12
        let popupGap: CGFloat = 8
        let anchor = NSPoint(
            x: inputRect.minX - composerHorizontalPadding,
            y: inputRect.maxY + composerTopPadding + popupGap
        )
        return (
            window.convertPoint(toScreen: anchor),
            inputRect.width + composerHorizontalPadding * 2,
            window.frame
        )
    }

    // MARK: - Override text changes to track token deletions

    override func didChangeText() {
        super.didChangeText()
        notifyTokensChanged()
    }
}

