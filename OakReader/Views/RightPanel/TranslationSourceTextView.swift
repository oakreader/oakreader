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

        // Increase line height for better readability
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.4
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.paragraphStyle] = paragraphStyle

        // Disable smart substitutions
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

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
        private var lastSelectionWasEmpty = true

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
            guard let textView else { return }
            let range = textView.selectedRange()

            // Only trigger on non-empty word selection (double-click selects a word)
            guard range.length > 0 else {
                lastSelectionWasEmpty = true
                return
            }

            // Skip if the previous selection was already non-empty (drag extending)
            if !lastSelectionWasEmpty { return }
            lastSelectionWasEmpty = false

            let nsString = textView.string as NSString
            let selectedWord = nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)

            // Only trigger for single-word selections (no spaces)
            guard !selectedWord.isEmpty,
                  !selectedWord.contains(" "),
                  selectedWord.count <= 30 else { return }

            // Extract sentence context
            let sentence = extractSentence(from: textView.string, around: range)

            // Get screen point for popup positioning
            let glyphRange = textView.layoutManager?.glyphRange(forCharacterRange: range, actualCharacterRange: nil) ?? range
            var rect = textView.layoutManager?.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer!) ?? .zero
            rect = rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
            let pointInView = NSPoint(x: rect.midX, y: rect.minY)
            let pointInWindow = textView.convert(pointInView, to: nil)
            let screenPoint = textView.window?.convertPoint(toScreen: pointInWindow) ?? pointInWindow

            parent.onWordSelected?(selectedWord, sentence, screenPoint)
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
