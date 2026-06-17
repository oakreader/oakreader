import SwiftUI
import PDFKit

struct ContentView: View {
    let viewModel: DocumentViewModel

    // MARK: - Sheet State

    @State private var showExportSheet = false
    @State private var showImportSheet = false
    @State private var showAccessibilityChecker = false

    // MARK: - Notification Observer

    @State private var actionObserver: Any?
    @State private var rightPanelWidth: CGFloat = OakStyle.Size.rightPanelWidth
    @State private var sidebarWidth: CGFloat = 240  // idealWidth

    var body: some View {
        GeometryReader { geometry in
            let maxRightPanel = geometry.size.width * 0.6

            HStack(spacing: 0) {
                // Left sidebar — full height
                if viewModel.state.isSidebarVisible {
                    sidebarContentView
                        .frame(width: effectiveSidebarWidth)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .onHover { inside in if inside { NSCursor.arrow.set() } }

                    panelDivider { delta in
                        let range = sidebarWidthRange
                        sidebarWidth = min(max(effectiveSidebarWidth + delta, range.lowerBound), range.upperBound)
                    }
                }

                // Main content column. The per-document toolbar sits at the
                // top of THIS column (not the window's full width) so the
                // sidebar / right panel can extend from below the tab bar all
                // the way down — see DocumentToolbarView's doc comment for the
                // rationale.
                VStack(spacing: 0) {
                    if shouldShowToolbar {
                        DocumentToolbarView(viewModel: viewModel)
                    }

                    // Main content area
                    ZStack {
                        if viewModel.isNewTab {
                            NewTabView(viewModel: viewModel)
                        } else if viewModel.hasDocument {
                            mainContentView
                        } else {
                            emptyStateView
                        }

                        // Loading overlay
                        if viewModel.state.isLoading {
                            ProgressOverlay(message: "Processing...")
                        }
                    }
                    .frame(minWidth: 300)
                    .frame(maxWidth: .infinity)
                    // Clip the column to its laid-out bounds. The live-web
                    // WKWebView is a heavyweight, layer-backed NSView that does
                    // NOT respect its SwiftUI frame when the HStack shrinks this
                    // column to make room for the right panel — it keeps drawing
                    // at full width and, because native AppKit views always
                    // composite above sibling SwiftUI content, bleeds over the
                    // chat panel (making it look transparent). Clipping forces
                    // the web view to stay inside the content column.
                    .clipped()
                }
                .background(OakStyle.Colors.contentBackground)

                // Right panel — draggable divider (full height under tab bar)
                if viewModel.state.rightPanelMode != nil {
                    panelDivider { delta in
                        rightPanelWidth = min(max(rightPanelWidth - delta, 400), maxRightPanel)
                    }

                    RightPanelContentView(viewModel: viewModel)
                        .frame(width: min(rightPanelWidth, maxRightPanel))
                        .background(Color(nsColor: .controlBackgroundColor))
                        .onHover { inside in if inside { NSCursor.arrow.set() } }
                }
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 2,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: OakStyle.Radius.standard
                )
            )
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            if let artifact = viewModel.studioFullScreenArtifact {
                StudioFullScreenView(
                    artifact: artifact,
                    onClose: { viewModel.studioFullScreenArtifact = nil },
                    onJumpToSource: { quote, page in
                        viewModel.studio.jumpToSource(anchorText: quote, page1Based: page)
                    },
                    onDeleteCard: { index in
                        viewModel.studio.deleteQuizCard(artifact, at: index)
                    }
                )
            }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.state.showError },
            set: { viewModel.state.showError = $0 }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = viewModel.state.errorMessage {
                Text(message)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showAccessibilityChecker) {
            AccessibilityCheckerView(viewModel: viewModel)
        }
        .onAppear {
            setupActionObserver()
        }
        .onDisappear { removeActionObserver() }
    }

    /// Only render the per-document toolbar when it has content-specific
    /// affordances to add (PDF nav/zoom/tools, HTML annotation tools, live web
    /// address bar). Markdown notes, embed cards, the new-tab router, and
    /// presentation mode all skip it — the tab-bar anchors suffice.
    private var shouldShowToolbar: Bool {
        if viewModel.isNewTab { return false }
        if viewModel.state.isPresentationMode { return false }
        switch viewModel.contentType {
        // PDF dropped its per-document toolbar — zoom/markup/area now live in
        // menus, the selection popup, and the Command Palette. HTML still keeps
        // its annotation cluster, and live web keeps the address bar.
        case .pdf:        return false
        case .html:       return viewModel.hasDocument
        case .link:       return viewModel.liveURL != nil
        case .markdown,
             .audio:       return false
        }
    }

    private var sidebarWidthRange: ClosedRange<CGFloat> {
        140...380
    }

    private var effectiveSidebarWidth: CGFloat {
        sidebarWidth
    }

    @ViewBuilder
    private var sidebarContentView: some View {
        if viewModel.contentType == .markdown {
            MarkdownOutlineSidebarView(viewModel: viewModel)
        } else if viewModel.contentType == .link || viewModel.contentType == .html {
            // Snapshots and live web render through the same WKWebView, so they
            // share the same Contents (heading outline) + Search (find-in-page)
            // sidebar instead of borrowing the PDF thumbnails/outline tabs.
            WebTOCSidebarView(viewModel: viewModel)
        } else {
            SidebarView(viewModel: viewModel)
        }
    }

    // MARK: - Draggable Panel Divider

    /// 1px visible line with a wider invisible hit zone (11px) for easy dragging.
    private func panelDivider(onDrag: @escaping (CGFloat) -> Void) -> some View {
        Color.white
            .frame(width: 11)
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        onDrag(value.translation.width)
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContentView: some View {
        switch viewModel.contentType {
        case .pdf:
            ZStack {
                PDFViewerRepresentable(viewModel: viewModel)

                if viewModel.state.editorMode == .snapshot {
                    SnapshotOverlayView(viewModel: viewModel)
                }
            }
        case .html:
            ZStack {
                HTMLViewerRepresentable(viewModel: viewModel)
                if viewModel.state.editorMode == .snapshot {
                    HTMLOverlayView(viewModel: viewModel)
                }
            }
        case .link:
            let isLiveLink = viewModel.liveURL != nil
            ZStack {
                if isLiveLink {
                    liveWebView
                } else {
                    EmbedCardView(viewModel: viewModel)
                }
                if viewModel.state.editorMode == .snapshot {
                    MediaSnapshotOverlayView(viewModel: viewModel)
                }
            }
            .padding(.horizontal, isLiveLink ? 0 : 8)
            .padding(.bottom, isLiveLink ? 0 : 8)
        case .markdown:
            MarkdownPreviewView(viewModel: viewModel)
        case .audio:
            Text("Audio playback not yet available")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // The per-document toolbar (address bar + nav + tools) lives in the shared
    // window chrome (RootView), not here — see DocumentToolbarView. This keeps a
    // single active-tab-aware toolbar instead of one per kept-alive ContentView.
    private var liveWebView: some View {
        // Load progress renders inside the address field (DocumentToolbarView),
        // not as a separate bar over the page.
        HTMLViewerRepresentable(viewModel: viewModel)
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No Document")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open a PDF file to get started.")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Action Observer

    private func setupActionObserver() {
        actionObserver = NotificationCenter.default.addObserver(
            forName: .documentAction,
            object: nil,
            queue: .main
        ) { notification in
            guard let action = notification.object as? DocumentAction else { return }
            handleSheetAction(action)
        }
    }

    private func removeActionObserver() {
        if let observer = actionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleSheetAction(_ action: DocumentAction) {
        switch action {
        case .exportImages:
            showExportSheet = true
        case .accessibilityCheck:
            showAccessibilityChecker = true
        default:
            break
        }
    }
}
