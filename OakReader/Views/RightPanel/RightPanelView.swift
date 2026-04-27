import SwiftUI

/// Resizable right panel content shown inside HSplitView.
struct RightPanelContentView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        Group {
            if let mode = viewModel.state.rightPanelMode {
                switch mode {
                case .inspector:
                    InspectorPanelView(viewModel: viewModel)
                case .aiChat:
                    AIChatView(chatVM: viewModel.chat)
                case .notes:
                    NotePanelView(notesVM: viewModel.notes)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
