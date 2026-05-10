import SwiftUI

struct VoicePanelContainerView: View {
    let characterListVM: CharacterListViewModel
    let voiceVM: VoiceViewModel

    var body: some View {
        Group {
            switch characterListVM.screen {
            case .characterList:
                CharacterListView(viewModel: characterListVM)

            case .inCall(let character):
                VoiceChatView(
                    voiceVM: voiceVM,
                    onBack: {
                        voiceVM.stop()
                        characterListVM.finalizeCall(turnCount: voiceVM.turns.count)
                        voiceVM.turns.removeAll()
                        characterListVM.backToList()
                    },
                    characterName: character.name
                )
                .onAppear {
                    Task {
                        await voiceVM.start(
                            character: character,
                            callId: characterListVM.activeCall?.id.uuidString
                        )
                    }
                }

            case .callHistory(let character):
                CallHistoryView(
                    viewModel: characterListVM,
                    character: character
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: characterListVM.screen)
    }
}
