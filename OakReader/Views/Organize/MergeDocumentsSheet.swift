import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct MergeDocumentsSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var documentURLs: [URL] = []
    @State private var isMerging = false
    @State private var errorMessage: String?
    @State private var draggedIndex: Int?

    var body: some View {
        VStack(spacing: 16) {
            Text("Merge Documents")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Add PDF files to merge into the current document.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // File list
            if documentURLs.isEmpty {
                DropZoneView(
                    supportedTypes: [.pdf],
                    label: "Drop PDF files here",
                    icon: "arrow.triangle.merge"
                ) { urls in
                    documentURLs.append(contentsOf: urls)
                }
                .frame(height: 150)
            } else {
                VStack(spacing: 0) {
                    List {
                        ForEach(Array(documentURLs.enumerated()), id: \.offset) { index, url in
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                    if let size = FileCoordination.fileSizeString(for: url) {
                                        Text(size)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button {
                                    documentURLs.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .onMove { source, destination in
                            documentURLs.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(height: 200)

                    HStack {
                        Button {
                            addFiles()
                        } label: {
                            Label("Add Files", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)

                        Spacer()

                        Text("\(documentURLs.count) documents")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
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

                Button("Merge") {
                    mergeDocuments()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(documentURLs.isEmpty || isMerging)
            }
        }
        .padding()
        .frame(width: 480, height: 450)
        .overlay {
            if isMerging {
                ProgressOverlay(message: "Merging documents...")
            }
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK {
            documentURLs.append(contentsOf: panel.urls)
        }
    }

    private func mergeDocuments() {
        isMerging = true
        errorMessage = nil

        guard let mainDoc = viewModel.pdfDocument else {
            errorMessage = "No document open."
            isMerging = false
            return
        }

        for url in documentURLs {
            guard let mergeDoc = PDFDocument(url: url) else {
                errorMessage = "Failed to load: \(url.lastPathComponent)"
                isMerging = false
                return
            }

            for i in 0..<mergeDoc.pageCount {
                guard let page = mergeDoc.page(at: i) else { continue }
                mainDoc.insert(page, at: mainDoc.pageCount)
            }
        }

        viewModel.markDocumentEdited()
        isMerging = false
        dismiss()
    }
}
