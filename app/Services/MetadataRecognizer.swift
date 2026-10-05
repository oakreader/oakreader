import Foundation

/// What a document is, as the core worked it out.
struct RecognizedMetadata {
    var cslItem: CSLItem
    /// `doi`, `arxiv`, `isbn`, `pmid`, `title-search`, `embedded` or `filename`.
    var method: String
    /// 0–1. Below 0.5 this describes the file rather than identifying it.
    var confidence: Double
    var provider: String?
    var trail: [String]

    /// "CrossRef · DOI", for the line under the panel's title.
    var summary: String {
        let how: String
        switch method {
        case "doi": how = "DOI"
        case "arxiv": how = "arXiv ID"
        case "isbn": how = "ISBN"
        case "pmid": how = "PubMed ID"
        case "title-search": how = "title search"
        case "embedded": how = "the document's own metadata"
        default: how = "the filename"
        }
        guard let provider, !provider.isEmpty else { return "From \(how)." }
        return "From \(how), via \(provider)."
    }

    /// Whether this is an identification rather than a description.
    var isResolved: Bool { confidence >= 0.5 }
}

/// Recognising a document, which the core does and this only asks for.
///
/// The Swift side used to own this: a DOI regex over three PDFKit pages, then
/// CrossRef. Two things were wrong with that beyond the narrowness. It ran on
/// the main thread, because opening a `PDFDocument` is synchronous and the
/// callers were `.onAppear`. And it could only ever work on a Mac, while the
/// catalog it writes into already runs anywhere.
///
/// Both go away by asking the core, which reads the file with pdf.js and
/// resolves against six services. See `backend/src/metadata/recognize.ts` for
/// the order it tries them in and why.
enum MetadataRecognizer {
    static func recognize(
        fileURL: URL?,
        title: String? = nil,
        author: String? = nil,
        identifier: String? = nil,
        offline: Bool = false
    ) async throws -> RecognizedMetadata {
        let result = try await NodeBackend.shared.call(
            RPC.Method.metadataRecognize,
            params: RPC.MetadataRecognizeParams(
                filePath: identifier == nil ? fileURL?.path : nil,
                fileName: fileURL?.lastPathComponent,
                title: title,
                author: author,
                identifier: identifier,
                offline: offline),
            as: RPC.MetadataRecognizeResult.self)

        guard let data = result.cslJson.data(using: .utf8),
              let cslItem = try? JSONDecoder().decode(CSLItem.self, from: data) else {
            throw RecognizerError.undecodableCSL
        }

        return RecognizedMetadata(
            cslItem: cslItem,
            method: result.method,
            confidence: result.confidence,
            provider: result.provider,
            trail: result.trail)
    }

    enum RecognizerError: LocalizedError {
        case undecodableCSL

        var errorDescription: String? {
            switch self {
            case .undecodableCSL: "The core returned metadata this build cannot read."
            }
        }
    }
}
