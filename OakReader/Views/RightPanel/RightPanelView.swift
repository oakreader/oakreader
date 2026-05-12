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
                    ItemSidebarPanel(viewModel: viewModel)
                case .aiChat:
                    AIChatView(
                        chatVM: viewModel.chat,
                        onSaveAssistantResponse: saveAssistantResponseAction
                    )
                case .voiceChat:
                    if let characterListVM = viewModel.characterListVM {
                        VoicePanelContainerView(
                            characterListVM: characterListVM,
                            voiceVM: viewModel.voice
                        )
                    } else {
                        VoiceChatView(voiceVM: viewModel.voice)
                    }
                case .notes:
                    if Preferences.shared.isPluginEnabled(.notes) {
                        NotePanelView(notesVM: viewModel.notes)
                    }
                case .translation:
                    if Preferences.shared.isPluginEnabled(.translation) {
                        TranslationPanelView(translationVM: viewModel.translation)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var saveAssistantResponseAction: ((Turn) -> Bool)? {
        Preferences.shared.isPluginEnabled(.notes) ? saveAssistantResponseToNote : nil
    }

    private func saveAssistantResponseToNote(_ turn: Turn) -> Bool {
        viewModel.notes.addChatResponseToNote(turn.content)
    }
}
