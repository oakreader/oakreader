import SwiftUI
import PDFKit
import OakGraph

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
        HStack(spacing: 0) {
            // Sidebar + Content wrapped together for unified corner radius
            HStack(spacing: 0) {
                // Left sidebar — full height
                if viewModel.state.isSidebarVisible {
                    sidebarContentView
                        .frame(width: effectiveSidebarWidth)
                        .background(Color(nsColor: .controlBackgroundColor))

                    panelDivider { delta in
                        let range = sidebarWidthRange
                        sidebarWidth = min(max(effectiveSidebarWidth + delta, range.lowerBound), range.upperBound)
                    }
                }

                // Main content column (toolbar + content)
                VStack(spacing: 0) {
                    // Inline toolbar (below tab bar) — hidden for embed and EPUB documents
                    if viewModel.itemType == .pdf || viewModel.itemType == .webSnapshot {
                        OakReaderToolbarView(viewModel: viewModel)
                        Divider()
                    } else {
                        Spacer().frame(height: 8)
                    }

                    // Main content area
                    ZStack {
                        if viewModel.hasDocument {
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
                }
                .background(OakStyle.Colors.contentBackground)

                // Right panel — draggable divider (full height under tab bar)
                if viewModel.state.rightPanelMode != nil {
                    panelDivider { delta in
                        rightPanelWidth = min(max(rightPanelWidth - delta, 320), 720)
                    }

                    RightPanelContentView(viewModel: viewModel)
                        .frame(width: rightPanelWidth)
                        .background(Color(nsColor: .controlBackgroundColor))
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

            // Side navigation strip — spans full height (toolbar + content)
            SideNavView(rightPanelMode: Binding(
                get: { viewModel.state.rightPanelMode },
                set: { viewModel.state.rightPanelMode = $0 }
            ))
        }
        .overlay {
            if viewModel.graph.isFullScreen, let doc = viewModel.graph.currentDocument {
                graphFullScreenOverlay(document: doc)
            }
        }
        .background(OakStyle.Colors.tabBarBackground)
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
            adjustSidebarWidthForMediaIfNeeded()
        }
        .onChange(of: viewModel.usesMediaSidebar) { _, _ in
            adjustSidebarWidthForMediaIfNeeded()
        }
        .onDisappear { removeActionObserver() }
    }

    private var sidebarWidthRange: ClosedRange<CGFloat> {
        viewModel.usesMediaSidebar ? 260...460 : 140...380
    }

    private var effectiveSidebarWidth: CGFloat {
        viewModel.usesMediaSidebar ? max(sidebarWidth, 280) : sidebarWidth
    }

    @ViewBuilder
    private var sidebarContentView: some View {
        if viewModel.itemType == .epub {
            EPUBSidebarView(viewModel: viewModel)
        } else if viewModel.usesMediaSidebar {
            MediaSidebarView(viewModel: viewModel)
        } else {
            SidebarView(viewModel: viewModel)
        }
    }

    private func adjustSidebarWidthForMediaIfNeeded() {
        guard viewModel.usesMediaSidebar else { return }
        sidebarWidth = max(sidebarWidth, 280)
    }

    // MARK: - Full Screen Graph Overlay

    private func exitFullScreen() {
        viewModel.graph.isFullScreen = false
    }

    @ViewBuilder
    private func graphFullScreenOverlay(document: GraphDocument) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            GraphCanvasView(
                interaction: viewModel.graph.fullScreenInteraction,
                document: document,
                onNodeMoved: { nodeId, position in
                    viewModel.graph.moveNode(nodeId, to: position)
                },
                onNodeSelected: { _ in },
                onEdgeSelected: { _ in },
                onNodeDoubleTapped: { _ in },
                onDeleteRequested: {
                    viewModel.graph.deleteSelected()
                },
                onEditCommitted: { nodeId, newLabel in
                    viewModel.graph.updateNodeLabel(nodeId, label: newLabel)
                }
            )

            // Close button (top-right)
            VStack {
                HStack {
                    Text(document.title.isEmpty ? "Graph" : document.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        exitFullScreen()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onKeyPress(.escape) {
            exitFullScreen()
            return .handled
        }
        .focusable()
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
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContentView: some View {
        switch viewModel.itemType {
        case .pdf:
            ZStack {
                PDFViewerRepresentable(viewModel: viewModel)

                if viewModel.state.editorMode == .snapshot {
                    SnapshotOverlayView(viewModel: viewModel)
                }
            }
        case .webSnapshot:
            ZStack {
                WebArchiveViewerRepresentable(viewModel: viewModel)
                if viewModel.state.editorMode == .snapshot {
                    WebSnapshotOverlayView(viewModel: viewModel)
                }
            }
        case .embed:
            ZStack {
                if viewModel.mediaDocument?.metadata.resolvedEmbedType == .youtube {
                    MediaViewerView(viewModel: viewModel)
                } else {
                    EmbedCardView(viewModel: viewModel)
                }
                if viewModel.state.editorMode == .snapshot {
                    MediaSnapshotOverlayView(viewModel: viewModel)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        case .epub:
            EPUBViewerRepresentable(
                viewModel: viewModel,
                currentSpineIndex: viewModel.state.currentSpineIndex,
                navigationToken: viewModel.state.epubNavigationToken,
                navigationFragment: viewModel.state.epubNavigationFragment,
                navigationLabel: viewModel.state.epubNavigationLabel,
                fontSize: viewModel.state.epubFontSize,
                fontFamily: viewModel.state.epubFontFamily,
                theme: viewModel.state.epubTheme,
                margin: viewModel.state.epubMargin,
                lineHeight: viewModel.state.epubLineHeight,
                zoomLevel: viewModel.state.zoomLevel
            )
        }
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
