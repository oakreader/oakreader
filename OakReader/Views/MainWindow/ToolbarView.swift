import SwiftUI

struct OakReaderToolbarView: View {
    let viewModel: DocumentViewModel

    @State private var goToPageText = ""

    private let annotationTools: [AnnotationTool] = [
        .highlight, .underline, .stickyNote, .freeText
    ]

    var body: some View {
        HStack(spacing: 0) {
            leftSection
            Spacer(minLength: 4)
            centerSection
            Spacer(minLength: 4)
            rightSection
        }
        .padding(.horizontal, ZoteroStyle.Spacing.xs)
        .frame(height: ZoteroStyle.Size.toolbarHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { syncPageText() }
        .onChange(of: viewModel.state.currentPageIndex) { _, _ in
            syncPageText()
        }
    }

    // MARK: - Left Section

    private var leftSection: some View {
        HStack(spacing: ZoteroStyle.Spacing.xs) {
            ZoteroToolButton(
                systemImage: "sidebar.leading",
                isSelected: viewModel.state.isSidebarVisible,
                tooltip: "Toggle Sidebar"
            ) {
                viewModel.state.isSidebarVisible.toggle()
            }

            separator

            // Zoom
            ZoteroToolButton(
                systemImage: "minus.magnifyingglass",
                tooltip: "Zoom Out"
            ) {
                viewModel.viewer.zoomOut()
            }

            Text(viewModel.viewer.zoomPercentage)
                .font(.system(size: ZoteroStyle.Font.body).monospacedDigit())
                .frame(width: 40)

            ZoteroToolButton(
                systemImage: "plus.magnifyingglass",
                tooltip: "Zoom In"
            ) {
                viewModel.viewer.zoomIn()
            }

            ZoteroToolButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                tooltip: "Zoom to Fit"
            ) {
                viewModel.viewer.zoomToFit()
            }

            separator

            // Page navigation
            ZoteroToolButton(
                systemImage: "chevron.up",
                tooltip: "Previous Page"
            ) {
                viewModel.viewer.goToPage(viewModel.state.currentPageIndex - 1)
            }

            HStack(spacing: 3) {
                TextField("", text: $goToPageText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 38)
                    .multilineTextAlignment(.center)
                    .font(.system(size: ZoteroStyle.Font.body))
                    .onSubmit {
                        if let page = Int(goToPageText) {
                            viewModel.viewer.goToPage(page - 1)
                        }
                        syncPageText()
                    }
                Text("/ \(viewModel.pageCount)")
                    .font(.system(size: ZoteroStyle.Font.body).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ZoteroToolButton(
                systemImage: "chevron.down",
                tooltip: "Next Page"
            ) {
                viewModel.viewer.goToPage(viewModel.state.currentPageIndex + 1)
            }
        }
    }

    // MARK: - Center Section

    private var centerSection: some View {
        HStack(spacing: ZoteroStyle.Spacing.xs) {
            ForEach(annotationTools) { tool in
                annotationButton(for: tool)
            }

            // Area (snapshot)
            ZoteroToolButton(
                systemImage: "rectangle.dashed",
                isSelected: viewModel.state.editorMode == .snapshot,
                tooltip: "Area"
            ) {
                if viewModel.state.editorMode == .snapshot {
                    viewModel.setEditorMode(.viewer)
                } else {
                    viewModel.setEditorMode(.snapshot)
                }
            }

            // Ink
            ZoteroToolButton(
                systemImage: AnnotationTool.freehand.systemImage,
                isSelected: viewModel.state.editorMode == .annotate && (viewModel.annotation.currentTool == .freehand || viewModel.annotation.currentTool == .eraser),
                tooltip: "Ink"
            ) {
                if viewModel.state.editorMode == .annotate && (viewModel.annotation.currentTool == .freehand || viewModel.annotation.currentTool == .eraser) {
                    viewModel.annotation.currentTool = .none
                    viewModel.setEditorMode(.viewer)
                } else {
                    viewModel.annotation.currentTool = .freehand
                    viewModel.setEditorMode(.annotate)
                }
            }

            separator

            AnnotationColorDropdown(viewModel: viewModel)
        }
    }

    // MARK: - Right Section

    private var rightSection: some View {
        HStack(spacing: ZoteroStyle.Spacing.xs) {
            ZoteroToolButton(
                systemImage: "magnifyingglass",
                isSelected: viewModel.state.isSearchBarVisible,
                tooltip: "Find in Document"
            ) {
                viewModel.state.isSearchBarVisible.toggle()
                if !viewModel.state.isSearchBarVisible {
                    viewModel.viewer.clearSearch()
                }
            }
        }
    }

    // MARK: - Helpers

    private var separator: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, ZoteroStyle.Spacing.xxs)
    }

    private func annotationButton(for tool: AnnotationTool) -> some View {
        let isActive = viewModel.state.editorMode == .annotate && viewModel.annotation.currentTool == tool
        return ZoteroToolButton(
            systemImage: tool.systemImage,
            isSelected: isActive,
            tooltip: tool.label
        ) {
            if isActive {
                viewModel.annotation.currentTool = .none
                viewModel.setEditorMode(.viewer)
            } else {
                viewModel.annotation.currentTool = tool
                viewModel.setEditorMode(.annotate)
            }
        }
    }

    private func syncPageText() {
        goToPageText = "\(viewModel.state.currentPageIndex + 1)"
    }
}
