import SwiftUI

struct OakReaderToolbarView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            areaToolButton
        }
        .padding(.horizontal, OakStyle.Spacing.xs)
        .frame(height: OakStyle.Size.toolbarHeight)
        .background(Color(nsColor: .windowBackgroundColor))
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
}
