import SwiftUI
import OakAgent

struct SidebarView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab-style mode picker
            HStack(spacing: 2) {
                ForEach(SidebarMode.allCases) { mode in
                    let selected = viewModel.state.sidebarMode == mode
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.state.sidebarMode = mode
                        }
                    } label: {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                            .foregroundStyle(selected ? .primary : .secondary)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selected ? Color(nsColor: .textBackgroundColor) : .clear)
                                    .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(mode.label)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
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
