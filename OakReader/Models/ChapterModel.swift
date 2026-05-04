import Foundation

enum ChapterSource: String, Codable {
    case youtube    // Creator's native chapters from yt-dlp metadata
    case ai         // AI-generated from transcript
}

struct VideoChapter: Codable, Identifiable {
    let id: UUID
    let startTime: Double       // seconds
    let endTime: Double?        // seconds (nil for last chapter)
    let title: String
    let summary: String?        // AI chapters have this; native usually don't

    init(id: UUID = UUID(), startTime: Double, endTime: Double? = nil, title: String, summary: String? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.summary = summary
    }
}

struct ChapterData: Codable {
    let version: Int            // 1
    let generatedAt: String     // ISO 8601
    let videoDuration: Int?
    let source: ChapterSource   // "youtube" or "ai"
    let modelUsed: String?      // e.g. "claude-sonnet-4-6" (nil for youtube source)
    let chapters: [VideoChapter]

    static func load(from url: URL) -> ChapterData? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChapterData.self, from: data)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

enum ChapterGenerationStatus: Equatable {
    case idle
    case fetchingTranscript
    case extractingChapters     // extracting native YouTube chapters
    case generatingChapters     // AI generation in progress
    case completed(ChapterSource)
    case failed(String)
    case skipped(String)
}
