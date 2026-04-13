import SwiftUI

struct RedactionBurnInSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isApplying = false

    var body: some View {
        VStack(spacing: 16) {
            // Warning icon
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            Text("Apply Redactions")
                .font(.title3)
                .fontWeight(.semibold)

            VStack(spacing: 8) {
                Text("This action is permanent and cannot be undone.")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.red)

                Text("The content under the redacted areas will be permanently removed from the document. This includes text, images, and any other content within the marked regions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 380)

            Divider()

            // Summary
            VStack(alignment: .leading, spacing: 4) {
                let count = viewModel.security.redactionRegions.count
                let pages = Set(viewModel.security.redactionRegions.map(\.pageIndex))

                HStack {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.red)
                    Text("\(count) redaction\(count == 1 ? "" : "s") on \(pages.count) page\(pages.count == 1 ? "" : "s")")
                        .font(.caption)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.05))
            )

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Apply Redactions") {
                    applyRedactions()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isApplying || viewModel.security.redactionRegions.isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
        .overlay {
            if isApplying {
                ProgressOverlay(message: "Applying redactions...")
            }
        }
    }

    private func applyRedactions() {
        isApplying = true

        Task {
            await viewModel.security.applyRedactions()
            await MainActor.run {
                isApplying = false
                dismiss()
            }
        }
    }
}
