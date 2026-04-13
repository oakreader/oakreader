import Foundation
import PDFKit

struct MergeService {

    func merge(_ documents: [PDFDocument]) -> PDFDocument {
        let result = PDFDocument()

        for document in documents {
            for i in 0..<document.pageCount {
                guard let page = document.page(at: i) else { continue }
                if let copiedPage = page.copy() as? PDFPage {
                    result.insert(copiedPage, at: result.pageCount)
                }
            }
        }

        return result
    }

    func merge(urls: [URL]) throws -> PDFDocument {
        var documents: [PDFDocument] = []

        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw OakReaderError.fileNotFound(url)
            }
            guard let document = PDFDocument(url: url) else {
                throw OakReaderError.fileReadFailed(url, underlying: nil)
            }
            if document.isLocked {
                throw OakReaderError.passwordRequired
            }
            documents.append(document)
        }

        guard !documents.isEmpty else {
            throw OakReaderError.mergeError("No valid documents to merge.")
        }

        return merge(documents)
    }

    func mergeWithBookmarks(urls: [URL]) throws -> PDFDocument {
        let result = PDFDocument()
        let root = PDFOutline()

        for url in urls {
            guard let document = PDFDocument(url: url) else {
                throw OakReaderError.fileReadFailed(url, underlying: nil)
            }
            if document.isLocked {
                throw OakReaderError.passwordRequired
            }

            let insertStart = result.pageCount

            for i in 0..<document.pageCount {
                guard let page = document.page(at: i) else { continue }
                if let copiedPage = page.copy() as? PDFPage {
                    result.insert(copiedPage, at: result.pageCount)
                }
            }

            // Create a bookmark for this file
            let bookmark = PDFOutline()
            bookmark.label = url.deletingPathExtension().lastPathComponent
            if let firstPage = result.page(at: insertStart) {
                bookmark.destination = PDFDestination(page: firstPage, at: .zero)
            }
            root.insertChild(bookmark, at: root.numberOfChildren)
        }

        result.outlineRoot = root
        return result
    }
}
