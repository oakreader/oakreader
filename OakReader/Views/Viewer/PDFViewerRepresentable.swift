import SwiftUI
import PDFKit

// Custom PDFView subclass that suppresses the native selection markup toolbar
class OakReaderView: PDFView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // Remove PDFKit's built-in markup/annotation items from context menu
        menu.items.removeAll { item in
            let title = item.title.lowercased()
            return title.contains("markup") || title.contains("highlight")
                || title.contains("underline") || title.contains("strikethrough")
        }
        super.willOpenMenu(menu, with: event)
    }
}

struct PDFViewerRepresentable: NSViewRepresentable {
    let viewModel: DocumentViewModel

    func makeCoordinator() -> PDFViewCoordinator {
        PDFViewCoordinator(viewModel: viewModel)
    }

    @AppStorage("appearanceMode") private var appearanceMode: String = "system"

    func makeNSView(context: Context) -> PDFView {
        let pdfView = OakReaderView()
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.displayDirection = .vertical
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = NSColor.controlBackgroundColor
        pdfView.delegate = context.coordinator
        pdfView.isInMarkupMode = false
        applyDarkAppearanceContent(to: pdfView)

        pdfView.document = viewModel.pdfDocument
        pdfView.displayMode = viewModel.state.displayMode

        // Scale to fit page width on initial load
        DispatchQueue.main.async {
            pdfView.autoScales = true
            viewModel.state.zoomLevel = pdfView.scaleFactor
        }

        context.coordinator.setupObservers(for: pdfView)
        context.coordinator.pdfView = pdfView

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.pdfView = pdfView

        // Suppress native markup toolbar
        pdfView.isInMarkupMode = false

        // Update dark appearance content based on preference
        applyDarkAppearanceContent(to: pdfView)

        // Update document if changed
        if pdfView.document !== viewModel.pdfDocument {
            pdfView.document = viewModel.pdfDocument
            context.coordinator.setupObservers(for: pdfView)

            // Scale to fit when a new document is opened
            DispatchQueue.main.async {
                pdfView.autoScales = true
                viewModel.state.zoomLevel = pdfView.scaleFactor
            }
        }

        // Update display mode
        if pdfView.displayMode != viewModel.state.displayMode {
            pdfView.displayMode = viewModel.state.displayMode
        }

        // Update zoom — only if the user explicitly changed it
        // (skip if autoScales just set the factor)
        if !context.coordinator.isAutoScaling {
            let targetZoom = viewModel.state.zoomLevel
            if abs(pdfView.scaleFactor - targetZoom) > 0.001 {
                pdfView.scaleFactor = targetZoom
            }
        }

        // Navigate to page
        let targetPage = viewModel.state.currentPageIndex
        if let doc = pdfView.document,
           let currentPage = pdfView.currentPage {
            let currentIndex = doc.index(for: currentPage)
            if currentIndex != targetPage,
               let page = doc.page(at: targetPage) {
                pdfView.go(to: page)
            }
        }

        // Highlight current search selection
        if let selection = viewModel.viewer.currentSelection {
            pdfView.setCurrentSelection(selection, animate: true)
            if let page = selection.pages.first {
                pdfView.go(to: selection.bounds(for: page), on: page)
            }
        }
    }

    // MARK: - Dark Appearance

    private func applyDarkAppearanceContent(to pdfView: PDFView) {
        let sel = NSSelectorFromString("setAllowsDarkAppearanceContent:")
        guard pdfView.responds(to: sel) else { return }

        let shouldEnable: Bool
        switch appearanceMode {
        case "dark":
            shouldEnable = true
        case "light":
            shouldEnable = false
        default:
            // "system" — follow the effective appearance
            shouldEnable = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        pdfView.setValue(shouldEnable, forKey: "allowsDarkAppearanceContent")
    }
}
