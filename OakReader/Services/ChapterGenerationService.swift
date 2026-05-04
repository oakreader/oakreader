import Foundation
import OakReaderAI
import YoutubeTranscript

/// Orchestrates post-import chapter generation for YouTube videos.
/// Phase 1: Extract native YouTube chapters via yt-dlp metadata (free).
/// Phase 2: Generate AI chapters from transcript analysis (requires API key).
final class ChapterGenerationService {

    func run(
        itemStorageKey: String,
        attachmentStorageKey: String,
        sourceURL: URL,
        duration: Int?,
        transcriptAlreadyExists: Bool
    ) async {
        let chaptersURL = CatalogDatabase.attachmentChaptersURL(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attachmentStorageKey
        )

        // Skip if chapters already exist
        guard !FileManager.default.fileExists(atPath: chaptersURL.path) else {
            Log.info(Log.chapters, "Chapters already exist, skipping generation")
            return
        }

        guard let videoId = extractVideoId(from: sourceURL) else {
            Log.error(Log.chapters, "Could not extract video ID from \(sourceURL)")
            return
        }

        let ytDlpPath = Preferences.shared.ytDlpPath
        let hasYtDlp = !ytDlpPath.isEmpty && FileManager.default.isExecutableFile(atPath: ytDlpPath)
        let hasAIKey = KeychainService.apiKey(for: Preferences.shared.youtubeAIProvider) != nil

        // Skip entirely when neither yt-dlp nor AI is available
        guard hasYtDlp || hasAIKey else {
            Log.info(Log.chapters, "No yt-dlp and no AI key configured, skipping chapter generation")
            return
        }

        // Phase 1: Try native YouTube chapters via yt-dlp
        if hasYtDlp {
            if let chapterData = await extractNativeChapters(videoId: videoId, ytDlpPath: ytDlpPath, duration: duration) {
                do {
                    try chapterData.save(to: chaptersURL)
                    Log.info(Log.chapters, "Saved \(chapterData.chapters.count) native YouTube chapters")
                    return
                } catch {
                    Log.error(Log.chapters, "Failed to save native chapters: \(error)")
                }
            }
        }

        // Phase 2: AI chapters from transcript
        await generateAIChapters(
            videoId: videoId,
            ytDlpPath: ytDlpPath,
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attachmentStorageKey,
            chaptersURL: chaptersURL,
            duration: duration,
            transcriptAlreadyExists: transcriptAlreadyExists
        )
    }

    // MARK: - Phase 1: Native YouTube Chapters

    private func extractNativeChapters(videoId: String, ytDlpPath: String, duration: Int?) async -> ChapterData? {
        Log.info(Log.chapters, "Extracting native chapters for \(videoId)")

        let json = await runYtDlpMetadata(videoId: videoId, ytDlpPath: ytDlpPath)
        guard let json else { return nil }

        guard let chaptersArray = json["chapters"] as? [[String: Any]], !chaptersArray.isEmpty else {
            Log.info(Log.chapters, "No native chapters found in yt-dlp metadata")
            return nil
        }

        let chapters: [VideoChapter] = chaptersArray.map { raw in
            let start = raw["start_time"] as? Double ?? 0
            let end = raw["end_time"] as? Double
            let title = raw["title"] as? String ?? "Chapter"
            return VideoChapter(startTime: start, endTime: end, title: title)
        }

        return ChapterData(
            version: 1,
            generatedAt: Date().iso8601String,
            videoDuration: duration ?? (json["duration"] as? Int),
            source: .youtube,
            modelUsed: nil,
            chapters: chapters
        )
    }

    /// Run `yt-dlp -j --no-download` and return the parsed JSON dictionary.
    private func runYtDlpMetadata(videoId: String, ytDlpPath: String) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ytDlpPath)
                process.arguments = [
                    "-j",
                    "--no-download",
                    "https://www.youtube.com/watch?v=\(videoId)",
                ]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    Log.error(Log.chapters, "yt-dlp metadata process failed: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                guard process.terminationStatus == 0 else {
                    Log.error(Log.chapters, "yt-dlp metadata exited with status \(process.terminationStatus)")
                    continuation.resume(returning: nil)
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: json)
            }
        }
    }

    // MARK: - Phase 2: AI Chapters

    private func generateAIChapters(
        videoId: String,
        ytDlpPath: String,
        itemStorageKey: String,
        attachmentStorageKey: String,
        chaptersURL: URL,
        duration: Int?,
        transcriptAlreadyExists: Bool
    ) async {
        // Guard: skip for very short videos
        if let duration, duration < 180 {
            Log.info(Log.chapters, "Video too short (\(duration)s) for AI chapters, skipping")
            return
        }

        // Ensure transcript text is available
        let transcriptURL = CatalogDatabase.attachmentTranscriptURL(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attachmentStorageKey
        )

        var transcriptText: String?

        // Try loading from disk
        if transcriptAlreadyExists || FileManager.default.fileExists(atPath: transcriptURL.path) {
            transcriptText = try? String(contentsOf: transcriptURL, encoding: .utf8)
        }

        // Fetch transcript if not on disk
        if transcriptText == nil || transcriptText!.isEmpty {
            transcriptText = await fetchTranscript(videoId: videoId, ytDlpPath: ytDlpPath, saveURL: transcriptURL)
        }

        guard let transcript = transcriptText, !transcript.isEmpty else {
            Log.info(Log.chapters, "No transcript available for AI chapter generation")
            return
        }

        // Check for AI API key
        let prefs = Preferences.shared
        let config = ProviderConfig(
            provider: prefs.youtubeAIProvider,
            model: prefs.youtubeAIModel.isEmpty ? prefs.youtubeAIProvider.defaultModel : prefs.youtubeAIModel
        )

        let router = ProviderRouter()
        guard let provider = try? router.provider(for: config) else {
            Log.info(Log.chapters, "No AI API key configured, skipping AI chapter generation")
            return
        }

        Log.info(Log.chapters, "Generating AI chapters using \(config.provider.displayName) / \(config.model)")

        // Truncate transcript to 32K characters
        let truncated = String(transcript.prefix(32_000))

        let systemPrompt = Self.loadChapterPrompt()

        let messages = [LLMMessage(role: .user, text: truncated)]

        let stream = provider.sendMessage(
            messages: messages,
            model: config.model,
            systemPrompt: systemPrompt,
            maxTokens: 4096
        )

        var fullResponse = ""
        do {
            for try await chunk in stream {
                switch chunk {
                case .delta(let text):
                    fullResponse += text
                case .finished:
                    break
                case .error(let msg):
                    Log.error(Log.chapters, "AI stream error: \(msg)")
                    return
                }
            }
        } catch {
            Log.error(Log.chapters, "AI chapter generation failed: \(error)")
            return
        }

        guard !fullResponse.isEmpty else {
            Log.error(Log.chapters, "AI returned empty response")
            return
        }

        // Parse response JSON
        guard let chapters = parseAIResponse(fullResponse, duration: duration) else {
            Log.error(Log.chapters, "Failed to parse AI chapter response")
            return
        }

        let chapterData = ChapterData(
            version: 1,
            generatedAt: Date().iso8601String,
            videoDuration: duration,
            source: .ai,
            modelUsed: config.model,
            chapters: chapters
        )

        do {
            try chapterData.save(to: chaptersURL)
            Log.info(Log.chapters, "Saved \(chapters.count) AI-generated chapters")
        } catch {
            Log.error(Log.chapters, "Failed to save AI chapters: \(error)")
        }
    }

    // MARK: - Transcript Fetching

    private func fetchTranscript(videoId: String, ytDlpPath: String, saveURL: URL) async -> String? {
        // Try yt-dlp subtitle extraction
        if !ytDlpPath.isEmpty, FileManager.default.isExecutableFile(atPath: ytDlpPath) {
            if let text = await fetchTranscriptViaYtDlp(videoId: videoId, ytDlpPath: ytDlpPath) {
                try? text.write(to: saveURL, atomically: true, encoding: .utf8)
                return text
            }
        }

        // Fall back to YoutubeTranscript library
        do {
            let responses = try await YoutubeTranscript.fetchTranscript(for: videoId)
            let lines = responses.map { response in
                let totalSeconds = Int(response.offset)
                let m = totalSeconds / 60
                let s = totalSeconds % 60
                return "[\(m):\(String(format: "%02d", s))] \(response.text)"
            }
            let text = lines.joined(separator: "\n")
            if !text.isEmpty {
                try? text.write(to: saveURL, atomically: true, encoding: .utf8)
            }
            return text.isEmpty ? nil : text
        } catch {
            Log.error(Log.chapters, "YoutubeTranscript fallback failed: \(error)")
            return nil
        }
    }

    private func fetchTranscriptViaYtDlp(videoId: String, ytDlpPath: String) async -> String? {
        await withCheckedContinuation { continuation in
            Task.detached {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("oakreader-transcript-\(videoId)")

                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDir) }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: ytDlpPath)
                process.arguments = [
                    "--skip-download",
                    "--write-auto-sub",
                    "--write-sub",
                    "--sub-lang", "en",
                    "--sub-format", "json3",
                    "-o", tempDir.appendingPathComponent("%(id)s").path,
                    "https://www.youtube.com/watch?v=\(videoId)",
                ]
                process.standardOutput = Pipe()
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                let files = (try? FileManager.default.contentsOfDirectory(
                    at: tempDir, includingPropertiesForKeys: nil
                )) ?? []
                guard let subFile = files.first(where: { $0.pathExtension == "json3" }),
                      let data = try? Data(contentsOf: subFile),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let events = json["events"] as? [[String: Any]] else {
                    continuation.resume(returning: nil)
                    return
                }

                var lines: [String] = []
                for event in events {
                    guard let tStartMs = event["tStartMs"] as? Double,
                          let segs = event["segs"] as? [[String: Any]] else {
                        continue
                    }
                    let text = segs.compactMap { $0["utf8"] as? String }.joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, text != "\n" else { continue }

                    let totalSeconds = Int(tStartMs / 1000)
                    let m = totalSeconds / 60
                    let s = totalSeconds % 60
                    lines.append("[\(m):\(String(format: "%02d", s))] \(text)")
                }

                let result = lines.joined(separator: "\n")
                continuation.resume(returning: result.isEmpty ? nil : result)
            }
        }
    }

    // MARK: - AI Response Parsing

    private func parseAIResponse(_ response: String, duration: Int?) -> [VideoChapter]? {
        // Extract JSON from potential markdown code blocks
        let jsonString: String
        if let startRange = response.range(of: "["),
           let endRange = response.range(of: "]", options: .backwards) {
            jsonString = String(response[startRange.lowerBound...endRange.lowerBound])
        } else {
            return nil
        }

        guard let data = jsonString.data(using: .utf8) else { return nil }

        struct RawChapter: Decodable {
            let startTime: Double
            let title: String
            let summary: String?
        }

        guard let raw = try? JSONDecoder().decode([RawChapter].self, from: data),
              !raw.isEmpty else {
            return nil
        }

        // Compute endTime from next chapter's startTime
        var chapters: [VideoChapter] = []
        for (index, item) in raw.enumerated() {
            let endTime: Double?
            if index + 1 < raw.count {
                endTime = raw[index + 1].startTime
            } else if let duration {
                endTime = Double(duration)
            } else {
                endTime = nil
            }
            chapters.append(VideoChapter(
                startTime: item.startTime,
                endTime: endTime,
                title: item.title,
                summary: item.summary
            ))
        }

        return chapters
    }

    // MARK: - Helpers

    // MARK: - Prompt Loading

    static let defaultChapterPrompt = """
    You are a video chapter generator. Given a transcript with timestamps, \
    produce chapter markers that divide the video into logical sections.

    ## Rules

    - Each chapter covers approximately 3-10 minutes of content
    - First chapter MUST start at 0:00
    - Align chapters with natural topic transitions
    - Concise, descriptive titles (3-8 words)
    - Include a 1-sentence summary per chapter
    - Short videos (<15 min): 3-5 chapters
    - Medium videos (15-60 min): 6-12 chapters
    - Long videos (60+ min): up to 15-20 chapters

    ## Output Format

    Output ONLY a JSON array, no markdown fences:

    [{"startTime": <seconds>, "title": "...", "summary": "..."}]
    """

    static func loadChapterPrompt() -> String {
        let url = Preferences.chapterPromptURL
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8),
           !content.isEmpty {
            return content
        }

        // Create default prompt file
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? defaultChapterPrompt.write(to: url, atomically: true, encoding: .utf8)
        return defaultChapterPrompt
    }

    private func extractVideoId(from url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let vParam = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return vParam
        }
        if url.host == "youtu.be" {
            return url.pathComponents.last
        }
        if url.absoluteString.contains("/embed/") {
            return url.pathComponents.last
        }
        return nil
    }
}
