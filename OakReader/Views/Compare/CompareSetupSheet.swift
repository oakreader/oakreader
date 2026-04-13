import SwiftUI

// Stub: compare feature was removed from DocumentViewModel
struct CompareSetupSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("Document comparison is not available.")
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 300, height: 100)
    }
}
