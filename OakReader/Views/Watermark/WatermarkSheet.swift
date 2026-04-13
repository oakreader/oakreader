import SwiftUI

// Stub: watermark feature was removed from DocumentViewModel
struct WatermarkSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("Watermark feature is not available.")
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 300, height: 100)
    }
}
