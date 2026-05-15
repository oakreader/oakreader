import SwiftUI

struct VoicePanelContainerView: View {
    let callListVM: VoiceCallListViewModel
    let voiceVM: VoiceViewModel

    var body: some View {
        Group {
            switch callListVM.screen {
            case .callList:
                VoiceCallMainView(viewModel: callListVM)

            case .inCall:
                VoiceChatView(
                    voiceVM: voiceVM,
                    onBack: {
                        voiceVM.stop()
                        callListVM.finalizeCall(turnCount: voiceVM.turns.count)
                        voiceVM.turns.removeAll()
                        callListVM.backToMain()
                    },
                    characterName: "Voice AI"
                )
                .onAppear {
                    Task {
                        await voiceVM.start(
                            callId: callListVM.activeCall?.id.uuidString
                        )
                    }
                }

            case .callHistory:
                CallHistoryView(viewModel: callListVM)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: callListVM.screen)
    }
}
