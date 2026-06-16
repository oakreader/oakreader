import SwiftUI
import OakAgent

/// Resizable right panel content shown inside HSplitView.
struct RightPanelContentView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        Group {
            if let mode = viewModel.state.rightPanelMode {
                switch mode {
                case .metadata:
                    ItemPanelView(viewModel: viewModel)
                case .aiChat:
                    AIChatView(
                        chatVM: viewModel.chat,
                        voiceVM: viewModel.voice
                    )
                case .translation:
                    if Preferences.shared.isExtensionEnabled(.translation) {
                        TranslationPanelView(translationVM: viewModel.translation, voiceVM: viewModel.voice)
                    }
                case .studio:
                    StudioPanelView(viewModel: viewModel)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
