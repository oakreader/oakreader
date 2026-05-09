import SwiftUI

struct VoicePanelContainerView: View {
    let speakerListVM: SpeakerListViewModel
    let voiceVM: VoiceViewModel

    var body: some View {
        Group {
            switch speakerListVM.screen {
            case .speakerList:
                SpeakerListView(viewModel: speakerListVM)

            case .inCall(let speaker):
                VoiceChatView(
                    voiceVM: voiceVM,
                    onBack: {
                        voiceVM.stop()
                        speakerListVM.finalizeCall(turnCount: voiceVM.turns.count)
                        voiceVM.turns.removeAll()
                        speakerListVM.backToList()
                    },
                    speakerName: speaker.name
                )
                .onAppear {
                    Task {
                        await voiceVM.start(
                            speaker: speaker,
                            callId: speakerListVM.activeCall?.id.uuidString
                        )
                    }
                }

            case .callHistory(let speaker):
                CallHistoryView(
                    viewModel: speakerListVM,
                    speaker: speaker
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: speakerListVM.screen)
    }
}
