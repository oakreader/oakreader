import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ExportSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var exportFormat: ExportFormat = .images
    @State private var pageRange: PageRange = .all
    @State private var isExporting = false
    @State private var errorMessage: String?

    // Image options
    @State private var imageDPI: Int = 150
    @State private var imageFormat: ImageFormat = .png
    @State private var jpegQuality: CGFloat = 0.85

    enum ExportFormat: String, CaseIterable, Identifiable {
        case images = "Images"
        case rtf = "Rich Text (RTF)"
        case plainText = "Plain Text"

        var id: String { rawValue }

        var fileExtension: String {
            switch self {
            case .images: return "png"
            case .rtf: return "rtf"
            case .plainText: return "txt"
            }
        }
    }

    enum ImageFormat: String, CaseIterable {
        case png = "PNG"
        case jpeg = "JPEG"
        case tiff = "TIFF"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Export Document")
                .font(.title3)
                .fontWeight(.semibold)

            // Format picker
            Picker("Format:", selection: $exportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            // Format-specific options
            switch exportFormat {
            case .images:
                ImageExportOptionsView(
                    dpi: $imageDPI,
                    imageFormat: $imageFormat,
                    jpegQuality: $jpegQuality
                )
            case .rtf:
                Text("Export text content as Rich Text Format.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .plainText:
                Text("Export text content as plain text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Page range
            PageRangeSelector(pageRange: $pageRange, totalPages: viewModel.pageCount)

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

                Button("Export") {
                    performExport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
            }
        }
        .padding()
        .frame(width: 450)
        .overlay {
            if isExporting {
                ProgressOverlay(message: "Exporting...")
            }
        }
    }

    private func performExport() {
        isExporting = true
        errorMessage = nil

        switch exportFormat {
        case .images:
            exportAsImages()
        case .rtf, .plainText:
            exportAsText()
        }
    }

    private func exportAsImages() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.folder]
        savePanel.nameFieldStringValue = "Exported Images"
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let outputDir = savePanel.url else {
            isExporting = false
            return
        }

        guard let doc = viewModel.pdfDocument else {
            errorMessage = "No document available."
            isExporting = false
            return
        }

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let pages = resolvePages()
            for pageIndex in pages {
                guard let page = doc.page(at: pageIndex) else { continue }

                let scale = CGFloat(imageDPI) / 72.0
                let pageRect = page.bounds(for: .mediaBox)
                let size = CGSize(
                    width: pageRect.width * scale,
                    height: pageRect.height * scale
                )

                let thumbnail = page.thumbnail(of: size, for: .mediaBox)

                let ext: String
                let data: Data?

                switch imageFormat {
                case .png:
                    ext = "png"
                    data = thumbnail.tiffRepresentation.flatMap {
                        NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
                    }
                case .jpeg:
                    ext = "jpg"
                    data = thumbnail.tiffRepresentation.flatMap {
                        NSBitmapImageRep(data: $0)?.representation(
                            using: .jpeg,
                            properties: [.compressionFactor: jpegQuality]
                        )
                    }
                case .tiff:
                    ext = "tiff"
                    data = thumbnail.tiffRepresentation
                }

                if let data {
                    let fileURL = outputDir.appendingPathComponent("page_\(pageIndex + 1).\(ext)")
                    try data.write(to: fileURL)
                }
            }

            isExporting = false
            dismiss()
            NSWorkspace.shared.open(outputDir)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            isExporting = false
        }
    }

    private func exportAsText() {
        let savePanel = NSSavePanel()
        let ext = exportFormat == .rtf ? "rtf" : "txt"
        savePanel.allowedContentTypes = exportFormat == .rtf ? [.rtf] : [.plainText]
        savePanel.nameFieldStringValue = "\(viewModel.fileName.replacingOccurrences(of: ".pdf", with: "")).\(ext)"

        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else {
            isExporting = false
            return
        }

        guard let doc = viewModel.pdfDocument else {
            errorMessage = "No document available."
            isExporting = false
            return
        }

        var text = ""
        let pages = resolvePages()
        for pageIndex in pages {
            if let page = doc.page(at: pageIndex),
               let pageText = page.string {
                text += "--- Page \(pageIndex + 1) ---\n"
                text += pageText
                text += "\n\n"
            }
        }

        do {
            try text.write(to: outputURL, atomically: true, encoding: .utf8)
            isExporting = false
            dismiss()
            NSWorkspace.shared.open(outputURL)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            isExporting = false
        }
    }

    private func resolvePages() -> [Int] {
        switch pageRange {
        case .all: return Array(0..<viewModel.pageCount)
        case .range(let r): return Array(r)
        case .custom(let pages): return pages.sorted()
        }
    }
}
