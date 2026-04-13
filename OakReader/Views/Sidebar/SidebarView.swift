import SwiftUI

struct SidebarView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Icon-only mode picker
            HStack(spacing: 2) {
                ForEach(SidebarMode.allCases) { mode in
                    ZoteroToolButton(
                        systemImage: mode.systemImage,
                        isSelected: viewModel.state.sidebarMode == mode,
                        tooltip: mode.label
                    ) {
                        viewModel.state.sidebarMode = mode
                    }
                }
                Spacer()
            }
            .padding(.horizontal, ZoteroStyle.Spacing.xs)
            .padding(.vertical, ZoteroStyle.Spacing.xs)

            Divider()

            // Content
            switch viewModel.state.sidebarMode {
            case .thumbnails:
                ThumbnailSidebarView(viewModel: viewModel)
            case .bookmarks:
                BookmarkSidebarView(viewModel: viewModel)
            case .annotations:
                AnnotationListView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
