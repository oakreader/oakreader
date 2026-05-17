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
                        onSaveAssistantResponse: saveAssistantResponseAction,
                        onSaveQuizCard: saveQuizCardAction
                    )
                case .notes:
                    if Preferences.shared.isExtensionEnabled(.notes) {
                        NotePanelView(notesVM: viewModel.notes)
                    }
                case .translation:
                    if Preferences.shared.isExtensionEnabled(.translation) {
                        TranslationPanelView(translationVM: viewModel.translation)
                    }
                case .quizCards:
                    if Preferences.shared.isExtensionEnabled(.quizCards) {
                        QuizCardsPanelView(quizCardsVM: viewModel.quizCards) {
                            viewModel.appState?.openQuizReview(vm: viewModel.quizCards)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var saveAssistantResponseAction: ((Turn) -> Bool)? {
        Preferences.shared.isExtensionEnabled(.notes) ? saveAssistantResponseToNote : nil
    }

    private func saveAssistantResponseToNote(_ turn: Turn) -> Bool {
        viewModel.notes.addChatResponseToNote(turn.content)
    }

    private var saveQuizCardAction: ((QuizContent) -> Bool)? {
        Preferences.shared.isExtensionEnabled(.quizCards) ? saveQuizCard : nil
    }

    private func saveQuizCard(_ content: QuizContent) -> Bool {
        viewModel.quizCards.saveCard(content: content)
    }
}
