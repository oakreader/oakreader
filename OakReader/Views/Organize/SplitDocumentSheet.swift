import SwiftUI
import PDFKit

struct SplitDocumentSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var splitMode: SplitMode = .atPage
    @State private var splitPageNumber: Int = 1
    @State private var numberOfParts: Int = 2
    @State private var rangesText: String = ""
    @State private var isSplitting = false
    @State private var errorMessage: String?

    enum SplitMode: String, CaseIterable {
        case atPage = "At Page Number"
        case equalParts = "Into Equal Parts"
        case byRanges = "By Page Ranges"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Split Document")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Total pages: \(viewModel.pageCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Split mode picker
            Picker("Split Method", selection: $splitMode) {
                ForEach(SplitMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Divider()

            // Options
            switch splitMode {
            case .atPage:
                HStack {
                    Text("Split after page:")
                    TextField("Page", value: $splitPageNumber, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("(creates 2 documents)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .equalParts:
                HStack {
                    Text("Number of parts:")
                    TextField("Parts", value: $numberOfParts, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("(\(pagesPerPart) pages each)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .byRanges:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page ranges (one per line):")
                        .font(.caption)
                        .fontWeight(.medium)
                    TextEditor(text: $rangesText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 80)
                        .border(Color.secondary.opacity(0.3))
                    Text("Examples: 1-5, 6-10, 11-15")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

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

                Button("Split") {
                    splitDocument()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSplitting)
            }
        }
        .padding()
        .frame(width: 450)
        .overlay {
            if isSplitting {
                ProgressOverlay(message: "Splitting document...")
            }
        }
    }

    private var pagesPerPart: Int {
        guard numberOfParts > 0 else { return 0 }
        return (viewModel.pageCount + numberOfParts - 1) / numberOfParts
    }

    private func splitDocument() {
        isSplitting = true
        errorMessage = nil

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.folder]
        savePanel.nameFieldStringValue = "Split Output"
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let outputDir = savePanel.url else {
            isSplitting = false
            return
        }

        guard let doc = viewModel.pdfDocument else {
            errorMessage = "No document available."
            isSplitting = false
            return
        }

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let ranges: [[Int]]
            switch splitMode {
            case .atPage:
                let splitAt = max(1, min(splitPageNumber, doc.pageCount - 1))
                ranges = [
                    Array(0..<splitAt),
                    Array(splitAt..<doc.pageCount)
                ]
            case .equalParts:
                let perPart = pagesPerPart
                ranges = stride(from: 0, to: doc.pageCount, by: perPart).map { start in
                    Array(start..<min(start + perPart, doc.pageCount))
                }
            case .byRanges:
                ranges = parseRanges(rangesText, total: doc.pageCount)
            }

            let baseName = viewModel.fileName.replacingOccurrences(of: ".pdf", with: "")

            for (i, pageIndices) in ranges.enumerated() {
                let newDoc = PDFDocument()
                for (j, pageIndex) in pageIndices.enumerated() {
                    if let page = doc.page(at: pageIndex) {
                        newDoc.insert(page, at: j)
                    }
                }
                let outputURL = outputDir.appendingPathComponent("\(baseName)_part\(i + 1).pdf")
                newDoc.write(to: outputURL)
            }

            isSplitting = false
            dismiss()

            // Open output folder in Finder
            NSWorkspace.shared.open(outputDir)
        } catch {
            errorMessage = "Split failed: \(error.localizedDescription)"
            isSplitting = false
        }
    }

    private func parseRanges(_ text: String, total: Int) -> [[Int]] {
        text.split(separator: "\n")
            .compactMap { line -> [Int]? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("-") {
                    let parts = trimmed.split(separator: "-")
                    guard parts.count == 2,
                          let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                          let end = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
                    let s = max(0, start - 1)
                    let e = min(total - 1, end - 1)
                    return Array(s...e)
                } else if let page = Int(trimmed) {
                    return [max(0, page - 1)]
                }
                return nil
            }
    }
}
