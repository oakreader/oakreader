import SwiftUI

struct VoiceCallMainView: View {
    let viewModel: VoiceCallListViewModel

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer()

            // Start call button
            Button(action: { viewModel.startCall() }) {
                HStack(spacing: 8) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 14))
                    Text("Start Voice Call")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Capsule().fill(.green))
            }
            .buttonStyle(.plain)

            Spacer()

            // Call history link
            Button(action: { viewModel.showCallHistory() }) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                    Text("Call History")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Voice AI")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
