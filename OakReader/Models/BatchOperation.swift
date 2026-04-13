import Foundation

enum BatchOperationType: String, CaseIterable, Identifiable {
    case ocr
    case compress
    case watermark
    case headerFooter
    case convertToImages
    case merge
    case passwordProtect
    case removePassword
    case redactPattern
    case flattenAnnotations

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ocr: return "Run OCR"
        case .compress: return "Compress"
        case .watermark: return "Add Watermark"
        case .headerFooter: return "Add Headers/Footers"
        case .convertToImages: return "Convert to Images"
        case .merge: return "Merge into One PDF"
        case .passwordProtect: return "Add Password"
        case .removePassword: return "Remove Password"
        case .redactPattern: return "Redact Pattern"
        case .flattenAnnotations: return "Flatten Annotations"
        }
    }

    var systemImage: String {
        switch self {
        case .ocr: return "text.viewfinder"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .watermark: return "drop.triangle"
        case .headerFooter: return "textformat.abc"
        case .convertToImages: return "photo"
        case .merge: return "arrow.triangle.merge"
        case .passwordProtect: return "lock"
        case .removePassword: return "lock.open"
        case .redactPattern: return "eye.slash"
        case .flattenAnnotations: return "square.stack.3d.down.right"
        }
    }
}

struct BatchJob: Identifiable {
    let id: UUID
    var fileURL: URL
    var status: BatchJobStatus
    var outputURL: URL?
    var error: String?

    init(fileURL: URL) {
        self.id = UUID()
        self.fileURL = fileURL
        self.status = .pending
        self.outputURL = nil
        self.error = nil
    }

    enum BatchJobStatus: Equatable {
        case pending
        case processing(progress: Double)
        case completed
        case failed

        var label: String {
            switch self {
            case .pending: return "Pending"
            case .processing(let p): return "Processing (\(Int(p * 100))%)"
            case .completed: return "Completed"
            case .failed: return "Failed"
            }
        }
    }
}
