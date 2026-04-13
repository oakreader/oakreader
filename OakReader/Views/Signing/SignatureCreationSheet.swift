import SwiftUI

// Stub: fillSign feature was removed from DocumentViewModel
struct SignatureCreationSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("Signature creation is not available.")
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 300, height: 100)
    }
}
