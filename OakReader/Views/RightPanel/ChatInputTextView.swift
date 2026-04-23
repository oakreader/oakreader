import SwiftUI

/// A multi-line text input that sends on Enter and inserts a newline on Cmd+Enter.
/// Reports its content height so the parent can size it to fit.
struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Ask about this PDF..."
    var onSend: () -> Void
    @Binding var contentHeight: CGFloat

    /// Shared reference so the parent SwiftUI view can trigger focus.
    class FocusRef {
        weak var textView: ChatNSTextView?
        func focus() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
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
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true

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

        if textView.string != text && !context.coordinator.isUpdating {
            context.coordinator.isUpdating = true
            textView.string = text
            context.coordinator.updatePlaceholder()
            context.coordinator.updateHeight()
            context.coordinator.isUpdating = false
        }

        textView.onSend = onSend
        focusRef.textView = textView
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        weak var textView: ChatNSTextView?
        var isUpdating = false
        private var placeholderView: NSTextField?

        init(_ parent: ChatInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            isUpdating = true
            parent.text = textView.string
            updatePlaceholder()
            updateHeight()
            isUpdating = false
        }

        func updateHeight() {
            guard let textView else { return }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let usedRect = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
            let lineHeight = textView.font?.pointSize ?? 14
            let newHeight = max(usedRect.height + 2, (lineHeight + 4) * 2)
            DispatchQueue.main.async {
                self.parent.contentHeight = min(newHeight, 120)
            }
        }

        func updatePlaceholder() {
            guard let textView else { return }
            if textView.string.isEmpty {
                if placeholderView == nil {
                    let label = NSTextField(labelWithString: parent.placeholder)
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
                        label.topAnchor.constraint(equalTo: textView.topAnchor),
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

// MARK: - Custom NSTextView

final class ChatNSTextView: NSTextView {
    var onSend: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
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

        super.keyDown(with: event)
    }
}
