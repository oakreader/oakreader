import Foundation
import GRDB

/// Maps a semantic chunk to the library item and its embedding data.
struct SemanticChunkRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "semantic_chunks"

    var id: String
    var itemId: String      // FK → items.id
    var chunkType: String   // "abstract" or "page"
    var pageStart: Int?
    var pageEnd: Int?
    var tokenCount: Int?
    var createdAt: String
    var embedding: Data?        // raw Float32 bytes
    var embeddingDim: Int?      // e.g. 1024
    var chunkText: String?      // original text for excerpts
    var embeddingModel: String? // e.g. "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"
    var embeddingProvider: String? // "local" or future cloud providers

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case itemId = "item_id"
        case chunkType = "chunk_type"
        case pageStart = "page_start"
        case pageEnd = "page_end"
        case tokenCount = "token_count"
        case createdAt = "created_at"
        case embedding
        case embeddingDim = "embedding_dim"
        case chunkText = "chunk_text"
        case embeddingModel = "embedding_model"
        case embeddingProvider = "embedding_provider"
    }

    // MARK: - Embedding Conversion

    /// Convert a Float array to raw Data (4 bytes per float, little-endian).
    static func embeddingToData(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Convert raw Data back to a Float array.
    static func dataToEmbedding(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }
}
