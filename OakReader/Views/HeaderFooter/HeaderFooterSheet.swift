import SwiftUI

// Stub: headerFooter feature was removed
struct HeaderFooterSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("Header & Footer feature is not available.")
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 300, height: 100)
    }
}
