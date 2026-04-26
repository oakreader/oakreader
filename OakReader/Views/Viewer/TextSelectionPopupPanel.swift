import Foundation
import PDFKit
import AppKit

// MARK: - Text Selection Popup Panel (OakReader-style)

class TextSelectionPopupPanel: NSPanel {
    private let viewModel: DocumentViewModel
    private let selection: PDFSelection
    private weak var pdfView: PDFView?
    private let onDismiss: () -> Void

    // When true, dismissing the popup (e.g. clicking outside) auto-applies highlight
    var autoHighlightOnDismiss = true

    // Anchor in PDF coordinate space so we can reposition on scroll
    private let anchorPage: PDFPage
    private let anchorPoint: NSPoint // PDF page coords: midX of selection, minY (bottom)
    private var scrollObserver: NSObjectProtocol?

    private static let annotationColors: [(NSColor, String)] = [
        (NSColor(red: 1.0, green: 0.83, blue: 0.0, alpha: 1.0), "Yellow"),      // #ffd400
        (NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0), "Red"),           // #ff6666
        (NSColor(red: 0.37, green: 0.70, blue: 0.21, alpha: 1.0), "Green"),      // #5fb236
        (NSColor(red: 0.18, green: 0.66, blue: 0.90, alpha: 1.0), "Blue"),       // #2ea8e5
        (NSColor(red: 0.64, green: 0.54, blue: 0.90, alpha: 1.0), "Purple"),     // #a28ae5
        (NSColor(red: 0.90, green: 0.43, blue: 0.93, alpha: 1.0), "Magenta"),    // #e56eee
        (NSColor(red: 0.95, green: 0.60, blue: 0.22, alpha: 1.0), "Orange"),     // #f19837
        (NSColor(red: 0.67, green: 0.67, blue: 0.67, alpha: 1.0), "Gray"),       // #aaaaaa
    ]

    init(at screenPoint: NSPoint, viewModel: DocumentViewModel, selection: PDFSelection, pdfView: PDFView, anchorPage: PDFPage, anchorPoint: NSPoint, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.selection = selection
        self.pdfView = pdfView
        self.anchorPage = anchorPage
        self.anchorPoint = anchorPoint
        self.onDismiss = onDismiss

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.hasShadow = true
        self.ignoresMouseEvents = false

        let contentView = buildContentView()
        self.contentView = contentView

        let contentSize = contentView.fittingSize
        self.setContentSize(contentSize)

        // Position: centered below selection
        let x = screenPoint.x - contentSize.width / 2
        let y = screenPoint.y - contentSize.height - 6
        self.setFrameOrigin(NSPoint(x: x, y: y))

        self.orderFront(nil)

        self.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 1
        }

        observeScroll()
    }

    private func observeScroll() {
        guard let pdfView else { return }
        // PDFView's document view is inside a scroll view; observe its clip view bounds changes
        if let scrollView = pdfView.enclosingScrollView ?? pdfView.subviews.compactMap({ $0 as? NSScrollView }).first {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.updatePosition()
            }
        }
    }

    func updatePosition() {
        guard let pdfView, let window = pdfView.window else { return }
        let viewPoint = pdfView.convert(anchorPoint, from: anchorPage)
        let windowPoint = pdfView.convert(viewPoint, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)

        let panelSize = self.frame.size
        let x = screenPoint.x - panelSize.width / 2
        let y = screenPoint.y - panelSize.height - 6
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func buildContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        // Row 1: Color dots — click to instantly highlight in that color
        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 10
        colorRow.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        for (color, name) in Self.annotationColors {
            let dot = ColorDotView(color: color, size: 20) { [weak self] in
                self?.applyHighlightKeepOpen(color: color)
            }
            dot.toolTip = name
            colorRow.addArrangedSubview(dot)
        }
        stack.addArrangedSubview(colorRow)

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep)

        // Row 2: Highlight (full width)
        let highlightBtn = PopupActionButton(
            systemImage: "highlighter",
            title: "Highlight"
        ) { [weak self] in
            self?.applyHighlight(color: self?.viewModel.annotation.strokeColor ?? NSColor(red: 1.0, green: 0.83, blue: 0.0, alpha: 1.0))
        }
        stack.addArrangedSubview(highlightBtn)
        highlightBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        highlightBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Row 3: Underline (full width)
        let underlineBtn = PopupActionButton(
            systemImage: "underline",
            title: "Underline"
        ) { [weak self] in
            self?.applyUnderline()
        }
        stack.addArrangedSubview(underlineBtn)
        underlineBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        underlineBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep2)

        // Row 4: Add to Chat (full width)
        let addToChatBtn = PopupActionButton(
            systemImage: "bubble.left",
            title: "Add to Chat"
        ) { [weak self] in
            self?.addToChat()
        }
        stack.addArrangedSubview(addToChatBtn)
        addToChatBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        addToChatBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Separator
        let sep3 = NSBox()
        sep3.boxType = .separator
        sep3.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep3)

        // Row 4: Copy (full width)
        let copyBtn = PopupActionButton(
            systemImage: "doc.on.doc",
            title: "Copy"
        ) { [weak self] in
            self?.copySelection()
        }
        stack.addArrangedSubview(copyBtn)
        copyBtn.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6).isActive = true
        copyBtn.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true

        // Background
        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 6

        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        return container
    }

    private func addToChat() {
        guard let text = selection.string, !text.isEmpty else { return }
        let pageIndex = viewModel.state.currentPageIndex
        viewModel.chat.addTextAttachment(text, pageIndex: pageIndex)
        viewModel.state.rightPanelMode = .aiChat
        pdfView?.clearSelection()
        dismissWithAction()
    }

    private func applyHighlightKeepOpen(color: NSColor) {
        viewModel.annotation.strokeColor = color
        viewModel.annotation.addHighlight(for: selection)
        pdfView?.clearSelection()
        dismissWithAction()
    }

    private func applyHighlight(color: NSColor) {
        viewModel.annotation.strokeColor = color
        viewModel.annotation.addHighlight(for: selection)
        pdfView?.clearSelection()
        dismissWithAction()
    }

    private func applyUnderline() {
        viewModel.annotation.addUnderline(for: selection)
        pdfView?.clearSelection()
        dismissWithAction()
    }

    private func copySelection() {
        if let text = selection.string {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        pdfView?.clearSelection()
        dismissWithAction()
    }

    /// Dismiss after an explicit action (no auto-highlight needed)
    private func dismissWithAction() {
        autoHighlightOnDismiss = false
        dismiss()
    }

    /// Dismiss the popup. If autoHighlightOnDismiss is true (user clicked outside),
    /// automatically apply highlight in the current color — OakReader-style behavior.
    func dismiss() {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }

        if autoHighlightOnDismiss {
            autoHighlightOnDismiss = false
            viewModel.annotation.addHighlight(for: selection)
            pdfView?.clearSelection()
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.onDismiss()
        })
    }
}

// Helper to pass annotation + color through NSMenuItem.representedObject
class AnnotationColorChange: NSObject {
    let annotation: PDFAnnotation
    let color: NSColor

    init(annotation: PDFAnnotation, color: NSColor) {
        self.annotation = annotation
        self.color = color
    }
}
