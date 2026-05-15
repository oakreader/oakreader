import SwiftUI

struct WorkspaceRootView: View {
    @Bindable var viewModel: WorkspaceViewModel
    let appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Left panel: Sources
            if viewModel.isSourcesPanelVisible {
                WorkspaceSourcesPanel(viewModel: viewModel, appState: appState)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: OakStyle.Radius.standard,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    ))
                    .overlay(
                        TopLeftBorderFill(radius: OakStyle.Radius.standard, thickness: 1)
                            .fill(Color(nsColor: .separatorColor))
                    )
            }

            // Center: Chat
            AIChatView(
                chatVM: viewModel.chatVM,
                onSaveAssistantResponse: nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right panel: Studio
            if let tab = viewModel.studioTab {
                Divider()
                WorkspaceStudioPanel(studioTab: tab, viewModel: viewModel, appState: appState)
            }

            // Side nav strip
            WorkspaceSideNavView(studioTab: $viewModel.studioTab)
        }
        .onHover { inside in if inside { NSCursor.arrow.set() } }
    }
}
