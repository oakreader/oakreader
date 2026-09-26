import SwiftUI
import PDFKit

// MARK: - PresentationOverlayView

struct PresentationOverlayView: View {
    let viewModel: DocumentViewModel
    @State private var showPageIndicator = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black

            PresentationPDFView(viewModel: viewModel, onPageChange: {
                flashPageIndicator()
            })

            // Page indicator HUD
            if showPageIndicator {
                VStack {
                    Spacer()
                    Text("\(viewModel.state.currentPageIndex + 1) / \(viewModel.pageCount)")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.15), in: Capsule())
                        .padding(.bottom, 32)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window == NSApp.keyWindow || window == viewModel.appState?.window else { return }
            if viewModel.state.isPresentationMode {
                viewModel.exitPresentationMode()
            }
        }
    }

    private func flashPageIndicator() {
        hideTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) {
            showPageIndicator = true
        }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                showPageIndicator = false
            }
        }
    }
}

// MARK: - PresentationPDFView

struct PresentationPDFView: NSViewRepresentable {
    let viewModel: DocumentViewModel
    var onPageChange: () -> Void

    func makeCoordinator() -> PresentationCoordinator {
        PresentationCoordinator(viewModel: viewModel, onPageChange: onPageChange)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displaysPageBreaks = false
        pdfView.pageShadowsEnabled = false
        pdfView.backgroundColor = .black
        pdfView.document = viewModel.pdfDocument

        if let doc = pdfView.document,
           let page = doc.page(at: viewModel.state.currentPageIndex) {
            pdfView.go(to: page)
        }

        context.coordinator.pdfView = pdfView
        context.coordinator.install()

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.onPageChange = onPageChange

        // Sync page from state → view
        let targetIndex = viewModel.state.currentPageIndex
        if let doc = pdfView.document,
           let currentPage = pdfView.currentPage {
            let currentIndex = doc.index(for: currentPage)
            if currentIndex != targetIndex, let page = doc.page(at: targetIndex) {
                pdfView.go(to: page)
            }
        }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: PresentationCoordinator) {
        coordinator.teardown()
    }
}

// MARK: - PresentationCoordinator

class PresentationCoordinator: NSObject {
    var viewModel: DocumentViewModel
    var onPageChange: () -> Void
    weak var pdfView: PDFView?

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var pageObserver: NSObjectProtocol?
    private var cursorHideTask: Task<Void, Never>?
    private var isCursorHidden = false

    init(viewModel: DocumentViewModel, onPageChange: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onPageChange = onPageChange
        super.init()
    }

    func install() {
        installKeyMonitor()
        installMouseMonitor()
        installPageObserver()
        scheduleCursorHide()
    }

    func teardown() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let observer = pageObserver {
            NotificationCenter.default.removeObserver(observer)
            pageObserver = nil
        }
        cursorHideTask?.cancel()
        cursorHideTask = nil
        unhideCursor()
    }

    deinit {
        teardown()
    }

    // MARK: - Key Monitor

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: // ESC
                self.viewModel.exitPresentationMode()
                return nil
            case 123, 126: // Left, Up arrow
                self.previousPage()
                return nil
            case 124, 125: // Right, Down arrow
                self.nextPage()
                return nil
            case 49: // Space
                if event.modifierFlags.contains(.shift) {
                    self.previousPage()
                } else {
                    self.nextPage()
                }
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Mouse Monitor

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.unhideCursor()
            self?.scheduleCursorHide()
            return event
        }
    }

    private func scheduleCursorHide() {
        cursorHideTask?.cancel()
        cursorHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.hideCursor()
        }
    }

    private func hideCursor() {
        guard !isCursorHidden else { return }
        NSCursor.hide()
        isCursorHidden = true
    }

    private func unhideCursor() {
        guard isCursorHidden else { return }
        NSCursor.unhide()
        isCursorHidden = false
    }

    // MARK: - Page Observer

    private func installPageObserver() {
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            guard let self, let pdfView = self.pdfView,
                  let page = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let index = doc.index(for: page)
            if self.viewModel.state.currentPageIndex != index {
                self.viewModel.viewer.goToPage(index)
                self.onPageChange()
            }
        }
    }

    // MARK: - Navigation

    private func previousPage() {
        viewModel.handleAction(.previousPage)
        onPageChange()
    }

    private func nextPage() {
        viewModel.handleAction(.nextPage)
        onPageChange()
    }
}
