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
    @State private var rightPanelWidth: CGFloat = ZoteroStyle.Size.rightPanelWidth
    @State private var sidebarWidth: CGFloat = 200  // idealWidth

    var body: some View {
        VStack(spacing: 0) {
            // Inline toolbar (below tab bar)
            OakReaderToolbarView(viewModel: viewModel)
            Divider()

            // Search bar (below toolbar, like Zotero)
            if viewModel.state.isSearchBarVisible {
                SearchBarView(viewModel: viewModel)
                Divider()
            }

            HStack(spacing: 0) {
                // Left sidebar — draggable divider
                if viewModel.state.isSidebarVisible {
                    SidebarView(viewModel: viewModel)
                        .frame(width: sidebarWidth)
                        .background(Color(nsColor: .controlBackgroundColor))

                    panelDivider { delta in
                        sidebarWidth = min(max(sidebarWidth + delta, 140), 380)
                    }
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

                // Right panel — draggable divider
                if viewModel.state.rightPanelMode != nil {
                    panelDivider { delta in
                        rightPanelWidth = min(max(rightPanelWidth - delta, 320), 720)
                    }

                    RightPanelContentView(viewModel: viewModel)
                        .frame(width: rightPanelWidth)
                        .background(Color(nsColor: .controlBackgroundColor))
                }

                // Side navigation strip — always visible
                Divider()
                SideNavView(rightPanelMode: Binding(
                    get: { viewModel.state.rightPanelMode },
                    set: { viewModel.state.rightPanelMode = $0 }
                ))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
        .onAppear { setupActionObserver() }
        .onDisappear { removeActionObserver() }
    }

    // MARK: - Draggable Panel Divider

    /// 1px visible line with a wider invisible hit zone (11px) for easy dragging.
    private func panelDivider(onDrag: @escaping (CGFloat) -> Void) -> some View {
        Color.clear
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
        ZStack {
            PDFViewerRepresentable(viewModel: viewModel)

            if viewModel.state.editorMode == .snapshot {
                SnapshotOverlayView(viewModel: viewModel)
            }
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
