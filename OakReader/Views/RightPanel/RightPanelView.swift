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
                        voiceVM: viewModel.voice,
                        onSaveQuizCard: saveQuizCardAction
                    )
                case .translation:
                    if Preferences.shared.isExtensionEnabled(.translation) {
                        TranslationPanelView(translationVM: viewModel.translation, voiceVM: viewModel.voice)
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

    private var saveQuizCardAction: ((QuizContent) -> Bool)? {
        Preferences.shared.isExtensionEnabled(.quizCards) ? saveQuizCard : nil
    }

    private func saveQuizCard(_ content: QuizContent) -> Bool {
        viewModel.quizCards.saveCard(content: content)
    }
}
