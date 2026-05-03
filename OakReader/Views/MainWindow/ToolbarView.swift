import SwiftUI

struct OakReaderToolbarView: View {
    let viewModel: DocumentViewModel

    @State private var goToPageText = ""

    private let annotationTools: [AnnotationTool] = [
        .highlight, .underline
    ]

    var body: some View {
        HStack(spacing: 0) {
            switch viewModel.itemType {
            case .pdf:
                leftSection
                Spacer()
                centerSection
            case .webSnapshot, .embed:
                Spacer()
                areaToolButton
            }
        }
        .padding(.horizontal, OakStyle.Spacing.xs)
        .frame(height: OakStyle.Size.toolbarHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if viewModel.itemType == .pdf { syncPageText() }
        }
        .onChange(of: viewModel.state.currentPageIndex) { _, _ in
            if viewModel.itemType == .pdf { syncPageText() }
        }
    }

    // MARK: - Left Section

    private var leftSection: some View {
        HStack(spacing: OakStyle.Spacing.xs) {
            // Zoom
            OakToolButton(
                systemImage: "minus.magnifyingglass",
                tooltip: "Zoom Out"
            ) {
                viewModel.viewer.zoomOut()
            }

            Text(viewModel.viewer.zoomPercentage)
                .font(.system(size: OakStyle.Font.body).monospacedDigit())
                .frame(width: 40)

            OakToolButton(
                systemImage: "plus.magnifyingglass",
                tooltip: "Zoom In"
            ) {
                viewModel.viewer.zoomIn()
            }

            OakToolButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                tooltip: "Zoom to Fit"
            ) {
                viewModel.viewer.zoomToFit()
            }

            separator

            // Page navigation
            OakToolButton(
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
                    .font(.system(size: OakStyle.Font.body))
                    .onSubmit {
                        if let page = Int(goToPageText) {
                            viewModel.viewer.goToPage(page - 1)
                        }
                        syncPageText()
                    }
                Text("/ \(viewModel.pageCount)")
                    .font(.system(size: OakStyle.Font.body).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            OakToolButton(
                systemImage: "chevron.down",
                tooltip: "Next Page"
            ) {
                viewModel.viewer.goToPage(viewModel.state.currentPageIndex + 1)
            }
        }
    }

    // MARK: - Center Section

    private var centerSection: some View {
        HStack(spacing: OakStyle.Spacing.xs) {
            ForEach(annotationTools) { tool in
                annotationButton(for: tool)
            }

            AnnotationColorDropdown(viewModel: viewModel)

            separator

            areaToolButton
        }
    }

    // MARK: - Area Tool

    private var areaToolButton: some View {
        OakToolButton(
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
    }

    // MARK: - Helpers

    private var separator: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, OakStyle.Spacing.xxs)
    }

    private func annotationButton(for tool: AnnotationTool) -> some View {
        let isActive = viewModel.state.editorMode == .annotate && viewModel.annotation.currentTool == tool
        return OakToolButton(
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
