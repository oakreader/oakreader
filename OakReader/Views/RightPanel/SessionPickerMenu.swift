import SwiftUI

struct SessionPickerMenu: View {
    let chatVM: ChatViewModel

    var body: some View {
        Menu {
            Button("Clear Chat") {
                chatVM.clearSession()
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Session Options")
    }
}
