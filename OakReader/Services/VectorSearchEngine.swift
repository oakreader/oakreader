import Accelerate
import Foundation
import GRDB

/// Brute-force cosine similarity search over GRDB-stored embeddings using vDSP.
enum VectorSearchEngine {
    struct SearchHit: Sendable {
        let chunkId: String
        let itemId: String
        let score: Float
        let chunkText: String
        let chunkType: String
        let pageStart: Int?
        let pageEnd: Int?
    }

    /// Search for the most similar chunks to a query embedding.
    /// Only searches chunks matching the given `embeddingModel` to avoid mixing incompatible dimensions.
    /// Vectors are assumed pre-normalized, so dot product == cosine similarity.
    static func search(
        queryEmbedding: [Float],
        dbQueue: DatabaseQueue,
        embeddingModel: String,
        maxResults: Int = 10,
        threshold: Float = 0.3
    ) async throws -> [SearchHit] {
        // Fetch all chunks with embeddings for this model
        let chunks: [(id: String, itemId: String, embedding: Data, chunkText: String, chunkType: String, pageStart: Int?, pageEnd: Int?)]
        chunks = try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, item_id, embedding, chunk_text, chunk_type, page_start, page_end
                FROM semantic_chunks
                WHERE embedding IS NOT NULL AND embedding_model = ?
                """, arguments: [embeddingModel])
            return rows.map { row in
                (
                    id: row["id"] as String,
                    itemId: row["item_id"] as String,
                    embedding: row["embedding"] as Data,
                    chunkText: (row["chunk_text"] as String?) ?? "",
                    chunkType: row["chunk_type"] as String,
                    pageStart: row["page_start"] as Int?,
                    pageEnd: row["page_end"] as Int?
                )
            }
        }

        guard !chunks.isEmpty else { return [] }

        let dim = queryEmbedding.count
        var hits: [SearchHit] = []

        for chunk in chunks {
            let chunkFloats = SemanticChunkRecord.dataToEmbedding(chunk.embedding)
            guard chunkFloats.count == dim else { continue }

            // Dot product of pre-normalized vectors == cosine similarity
            var score: Float = 0
            vDSP_dotpr(queryEmbedding, 1, chunkFloats, 1, &score, vDSP_Length(dim))

            if score >= threshold {
                hits.append(SearchHit(
                    chunkId: chunk.id,
                    itemId: chunk.itemId,
                    score: score,
                    chunkText: chunk.chunkText,
                    chunkType: chunk.chunkType,
                    pageStart: chunk.pageStart,
                    pageEnd: chunk.pageEnd
                ))
            }
        }

        // Sort by score descending, take top-K
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(maxResults))
    }
}
