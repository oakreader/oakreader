import SwiftUI

struct ProgressOverlay: View {
    let message: String
    var progress: Double? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }

                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if let onCancel {
                    Button("Cancel", role: .cancel) {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(30)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 10)
        }
    }
}
