import SwiftUI
import AppKit

/// NSViewRepresentable wrapping NSTextView for translation source input.
/// Detects double-click word selection and provides a callback with
/// the selected word, sentence context, and screen position for popup placement.
struct TranslationSourceTextView: NSViewRepresentable {
    @Binding var text: String
    /// Reported back to SwiftUI so the view can size itself to its content (no inner scrolling).
    @Binding var height: CGFloat
    var font: NSFont
    var placeholder: String = "Enter text"
    var onWordSelected: ((_ word: String, _ sentence: String, _ screenPoint: NSPoint) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = TranslationNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = font
        textView.insertionPointColor = .controlAccentColor

        // Modest line height for readability. Kept fairly tight because the
        // selection highlight fills the whole line fragment — a large multiplier
        // makes the drag-select band look like a thick band around the text.
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.2
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle

        // Disable smart substitutions
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Commit the explanation only when a selection gesture finishes (mouse-up),
        // so a drag that sweeps out a phrase fires once with its final range rather
        // than firing on every intermediate character during the drag.
        textView.onSelectionCommitted = { [weak coordinator = context.coordinator] in
            coordinator?.commitSelection()
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Set initial text
        textView.string = text
        context.coordinator.updatePlaceholder()
        context.coordinator.recalculateHeight()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TranslationNSTextView else { return }
        if textView.string != text && !context.coordinator.isUpdating {
            context.coordinator.isUpdating = true
            textView.string = text
            context.coordinator.updatePlaceholder()
            context.coordinator.isUpdating = false
        }
        if textView.font != font {
            textView.font = font
        }
        // Width may have changed (panel resize) → wrapping changes → recompute height.
        context.coordinator.recalculateHeight()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranslationSourceTextView
        weak var textView: TranslationNSTextView?
        var isUpdating = false
        /// The last selection we fired an explanation for — avoids re-firing for an
        /// unchanged selection (e.g. mouse-up after the range already settled).
        private var lastCommittedSelection = ""

        init(_ parent: TranslationSourceTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            isUpdating = true
            parent.text = textView.string
            updatePlaceholder()
            isUpdating = false
            recalculateHeight()
        }

        /// Measures the text's laid-out height and reports it to SwiftUI via the binding.
        func recalculateHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer).height
            let newHeight = used + textView.textContainerInset.height * 2
            // Avoid mutating SwiftUI state during a view-update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if abs(self.parent.height - newHeight) > 0.5 {
                    self.parent.height = newHeight
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Clearing the selection resets the dedup guard so re-selecting the same
            // text fires a fresh explanation. The actual firing happens on mouse-up
            // (commitSelection) so a drag commits once with its final range.
            guard let textView else { return }
            if textView.selectedRange().length == 0 {
                lastCommittedSelection = ""
            }
        }

        /// Called on mouse-up. Fires `onWordSelected` for the settled selection,
        /// which may be a single word (double-click) or a phrase (drag).
        func commitSelection() {
            guard let textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }

            let nsString = textView.string as NSString
            let selected = nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selected.isEmpty else { return }

            // Accept words and phrases, but not whole paragraphs — keep the selection
            // to a meaningful phrase-sized unit.
            let wordCount = selected.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
            guard selected.count <= 200, wordCount <= 12 else { return }

            // Don't re-fire for the same settled selection.
            guard selected != lastCommittedSelection else { return }
            lastCommittedSelection = selected

            let sentence = extractSentence(from: textView.string, around: range)

            // Get screen point for popup positioning
            let glyphRange = textView.layoutManager?.glyphRange(forCharacterRange: range, actualCharacterRange: nil) ?? range
            var rect = textView.layoutManager?.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer!) ?? .zero
            rect = rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
            let pointInView = NSPoint(x: rect.midX, y: rect.minY)
            let pointInWindow = textView.convert(pointInView, to: nil)
            let screenPoint = textView.window?.convertPoint(toScreen: pointInWindow) ?? pointInWindow

            parent.onWordSelected?(selected, sentence, screenPoint)
        }

        func updatePlaceholder() {
            guard let textView else { return }
            textView.showPlaceholder = textView.string.isEmpty
            textView.placeholderString = parent.placeholder
            textView.needsDisplay = true
        }

        private func extractSentence(from text: String, around range: NSRange) -> String {
            let nsString = text as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)

            // Find sentence boundaries (period, question mark, exclamation, newline)
            let sentenceBreakers = CharacterSet(charactersIn: ".!?\n")

            // Search backward for sentence start
            var start = range.location
            while start > 0 {
                let char = nsString.character(at: start - 1)
                if let scalar = Unicode.Scalar(char), sentenceBreakers.contains(scalar) {
                    break
                }
                start -= 1
            }

            // Search forward for sentence end
            var end = NSMaxRange(range)
            while end < fullRange.length {
                let char = nsString.character(at: end)
                if let scalar = Unicode.Scalar(char), sentenceBreakers.contains(scalar) {
                    end += 1
                    break
                }
                end += 1
            }

            let sentenceRange = NSRange(location: start, length: end - start)
            return nsString.substring(with: sentenceRange).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Custom NSTextView with Placeholder

class TranslationNSTextView: NSTextView {
    var showPlaceholder = true
    var placeholderString = "Enter text"
    /// Fired after a mouse selection gesture finishes (the range is final here).
    var onSelectionCommitted: (() -> Void)?

    // NSTextView runs its own modal event-tracking loop inside `mouseDown` for the
    // entire drag-select and swallows the matching `mouseUp` — so overriding
    // `mouseUp` never fires. Instead, `super.mouseDown` returns only once that loop
    // ends (on mouse-up), at which point the selection is final.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onSelectionCommitted?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if showPlaceholder && string.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: font ?? NSFont.systemFont(ofSize: 14),
            ]
            let inset = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            let point = NSPoint(x: inset.width + padding, y: inset.height)
            placeholderString.draw(at: point, withAttributes: attrs)
        }
    }
}
