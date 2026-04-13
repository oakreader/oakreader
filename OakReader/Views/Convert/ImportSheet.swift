import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ImportSheet: View {
    let viewModel: DocumentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var imageURLs: [URL] = []
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Create PDF from Images")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Add images to create a new PDF document. Drag to reorder.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if imageURLs.isEmpty {
                DropZoneView(
                    supportedTypes: [.image],
                    label: "Drop images here",
                    icon: "photo.on.rectangle"
                ) { urls in
                    imageURLs.append(contentsOf: urls)
                }
                .frame(height: 200)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, url in
                                HStack {
                                    if let image = NSImage(contentsOf: url) {
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 40, height: 40)
                                            .background(Color.white)
                                            .cornerRadius(4)
                                    }

                                    VStack(alignment: .leading) {
                                        Text(url.lastPathComponent)
                                            .font(.caption)
                                            .lineLimit(1)

                                        if let image = NSImage(contentsOf: url) {
                                            Text("\(Int(image.size.width)) x \(Int(image.size.height))")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    // Reorder buttons
                                    VStack(spacing: 2) {
                                        Button {
                                            if index > 0 {
                                                imageURLs.swapAt(index, index - 1)
                                            }
                                        } label: {
                                            Image(systemName: "chevron.up")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(index == 0)

                                        Button {
                                            if index < imageURLs.count - 1 {
                                                imageURLs.swapAt(index, index + 1)
                                            }
                                        } label: {
                                            Image(systemName: "chevron.down")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(index == imageURLs.count - 1)
                                    }

                                    Button {
                                        imageURLs.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .frame(height: 200)
                    .border(Color.secondary.opacity(0.2))

                    HStack {
                        Button {
                            addMoreImages()
                        } label: {
                            Label("Add More", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)

                        Spacer()

                        Text("\(imageURLs.count) images")
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

                Button("Create PDF") {
                    createPDF()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(imageURLs.isEmpty || isCreating)
            }
        }
        .padding()
        .frame(width: 480, height: 450)
        .overlay {
            if isCreating {
                ProgressOverlay(message: "Creating PDF...")
            }
        }
    }

    private func addMoreImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            imageURLs.append(contentsOf: panel.urls)
        }
    }

    private func createPDF() {
        isCreating = true
        errorMessage = nil

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = "Created.pdf"

        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else {
            isCreating = false
            return
        }

        let newDoc = PDFDocument()

        for (index, url) in imageURLs.enumerated() {
            guard let image = NSImage(contentsOf: url) else {
                errorMessage = "Failed to load image: \(url.lastPathComponent)"
                isCreating = false
                return
            }

            let page = PDFPage(image: image)
            if let page {
                newDoc.insert(page, at: index)
            }
        }

        if newDoc.write(to: outputURL) {
            isCreating = false
            dismiss()
            NSWorkspace.shared.open(outputURL)
        } else {
            errorMessage = "Failed to save PDF."
            isCreating = false
        }
    }
}
