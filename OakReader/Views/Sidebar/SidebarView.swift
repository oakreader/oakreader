import SwiftUI

struct SidebarView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab-style mode picker
            HStack(spacing: 0) {
                ForEach(SidebarMode.allCases) { mode in
                    let selected = viewModel.state.sidebarMode == mode
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.state.sidebarMode = mode
                        }
                    } label: {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: OakStyle.Font.icon))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .foregroundStyle(selected ? .white : .secondary)
                            .background(
                                Capsule()
                                    .fill(selected ? Color.accentColor : .clear)
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(mode.label)
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, OakStyle.Spacing.xs)

            // Content
            switch viewModel.state.sidebarMode {
            case .thumbnails:
                ThumbnailSidebarView(viewModel: viewModel)
            case .outline:
                BookmarkSidebarView(viewModel: viewModel)
            case .annotations:
                AnnotationListView(viewModel: viewModel)
            case .search:
                SearchSidebarView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
