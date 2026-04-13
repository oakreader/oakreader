import AppKit
import PDFKit
import UniformTypeIdentifiers

struct DragDropCoordinator {
    static let supportedImageTypes: [UTType] = [.jpeg, .png, .tiff, .bmp, .gif, .heic]
    static let supportedTypes: [UTType] = [.pdf] + supportedImageTypes

    static func canHandle(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            supportedTypes.contains { type in
                provider.hasItemConformingToTypeIdentifier(type.identifier)
            }
        }
    }

    static func loadPDFDocuments(from providers: [NSItemProvider]) async -> [PDFDocument] {
        var documents: [PDFDocument] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                if let url = await loadFileURL(from: provider),
                   let doc = PDFDocument(url: url) {
                    documents.append(doc)
                }
            } else {
                for imageType in supportedImageTypes {
                    if provider.hasItemConformingToTypeIdentifier(imageType.identifier) {
                        if let url = await loadFileURL(from: provider),
                           let image = NSImage(contentsOf: url),
                           let page = image.toPDFPage() {
                            let doc = PDFDocument()
                            doc.insert(page, at: 0)
                            documents.append(doc)
                        }
                        break
                    }
                }
            }
        }

        return documents
    }

    static func loadImages(from providers: [NSItemProvider]) async -> [NSImage] {
        var images: [NSImage] = []

        for provider in providers {
            for imageType in supportedImageTypes {
                if provider.hasItemConformingToTypeIdentifier(imageType.identifier) {
                    if let url = await loadFileURL(from: provider),
                       let image = NSImage(contentsOf: url) {
                        images.append(image)
                    }
                    break
                }
            }
        }

        return images
    }

    static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }
}
