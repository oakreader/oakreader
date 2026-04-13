import SwiftUI
import PDFKit

struct ExtractPagesSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var pageRange: PageRange = .all
    @State private var deleteAfterExtract = false
    @State private var isExtracting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Extract Pages")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Extract selected pages into a new PDF document.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            PageRangeSelector(pageRange: $pageRange, totalPages: viewModel.pageCount)

            Toggle("Delete pages from original after extraction", isOn: $deleteAfterExtract)
                .font(.caption)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Extract") {
                    extractPages()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isExtracting)
            }
        }
        .padding()
        .frame(width: 420)
        .overlay {
            if isExtracting {
                ProgressOverlay(message: "Extracting pages...")
            }
        }
    }

    private func extractPages() {
        isExtracting = true
        errorMessage = nil

        guard let doc = viewModel.pdfDocument else {
            errorMessage = "No document available."
            isExtracting = false
            return
        }

        let pagesToExtract = resolvePageIndices()
        guard !pagesToExtract.isEmpty else {
            errorMessage = "No pages selected for extraction."
            isExtracting = false
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "\(viewModel.fileName.replacingOccurrences(of: ".pdf", with: ""))_extracted.pdf"

        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else {
            isExtracting = false
            return
        }

        let newDoc = PDFDocument()
        for (i, pageIndex) in pagesToExtract.enumerated() {
            if let page = doc.page(at: pageIndex) {
                newDoc.insert(page, at: i)
            }
        }

        if newDoc.write(to: outputURL) {
            if deleteAfterExtract {
                // Delete from original in reverse order to preserve indices
                for pageIndex in pagesToExtract.reversed() {
                    doc.removePage(at: pageIndex)
                }
                viewModel.markDocumentEdited()
            }

            isExtracting = false
            dismiss()
            NSWorkspace.shared.open(outputURL)
        } else {
            errorMessage = "Failed to save extracted pages."
            isExtracting = false
        }
    }

    private func resolvePageIndices() -> [Int] {
        switch pageRange {
        case .all:
            return Array(0..<viewModel.pageCount)
        case .range(let r):
            return Array(r)
        case .custom(let pages):
            return pages.sorted()
        }
    }
}
