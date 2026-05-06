import Foundation
import Darwin
import OakReaderAI
import YoutubeTranscript

/// Determines whether to generate structural chapters or AI highlights.
enum ChapterGenerationMode {
    case chapters      // YouTube native + AI structural sections fallback → chapters.json
    case highlights    // AI highlights → highlights.json
}

/// Orchestrates post-import chapter generation for YouTube videos.
/// Phase 1: Extract native YouTube chapters via yt-dlp metadata (free).
/// Phase 2: Generate AI chapters from transcript analysis (requires API key).
final class ChapterGenerationService {
    private static let ytDlpMetadataTimeout: TimeInterval = 20
    private static let ytDlpTranscriptTimeout: TimeInterval = 45

    func run(
        itemStorageKey: String,
        attachmentStorageKey: String,
        sourceURL: URL,
        duration: Int?,
        transcriptAlreadyExists: Bool,
        tryNativeChapters: Bool = true,
        mode: ChapterGenerationMode = .chapters
    ) async {
        let outputURL: URL
        switch mode {
        case .chapters:
            outputURL = CatalogDatabase.attachmentChaptersURL(
                itemStorageKey: itemStorageKey,
                attachmentStorageKey: attachmentStorageKey
            )
        case .highlights:
            outputURL = CatalogDatabase.attachmentHighlightsURL(
                itemStorageKey: itemStorageKey,
                attachmentStorageKey: attachmentStorageKey
            )
        }

        // Skip if output already exists
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            Log.info(Log.chapters, "\(mode == .chapters ? "Chapters" : "Highlights") already exist, skipping generation")
            return
        }

        guard let videoId = extractVideoId(from: sourceURL) else {
            Log.error(Log.chapters, "Could not extract video ID from \(sourceURL)")
            return
        }

        let ytDlpPath = Preferences.shared.ytDlpPath
        let hasYtDlp = !ytDlpPath.isEmpty && FileManager.default.isExecutableFile(atPath: ytDlpPath)
        let hasAIKey = CredentialResolver.hasCredentials(for: Preferences.shared.youtubeAIProviderId)

        // For highlights mode, only AI is relevant
        if mode == .highlights {
            guard hasAIKey else {
                Log.info(Log.chapters, "No AI key configured, skipping highlight generation")
                return
            }
            await generateAIContent(
                videoId: videoId,
                ytDlpPath: ytDlpPath,
                itemStorageKey: itemStorageKey,
                attachmentStorageKey: attachmentStorageKey,
                outputURL: outputURL,
                duration: duration,
                transcriptAlreadyExists: transcriptAlreadyExists,
                mode: mode
            )
            return
        }

        // Chapters mode: try native first, then AI sections
        guard (tryNativeChapters && hasYtDlp) || hasAIKey else {
            Log.info(Log.chapters, "No yt-dlp and no AI key configured, skipping chapter generation")
            return
        }

        // Phase 1: Try native YouTube chapters via yt-dlp
        if tryNativeChapters, hasYtDlp {
            if let chapterData = await extractNativeChapters(videoId: videoId, ytDlpPath: ytDlpPath, duration: duration) {
                do {
                    try chapterData.save(to: outputURL)
                    Log.info(Log.chapters, "Saved \(chapterData.chapters.count) native YouTube chapters")

                    // Enrich native chapters with AI summaries if available
                    if hasAIKey {
                        await enrichChaptersWithSummaries(
                            chapterData: chapterData,
                            videoId: videoId,
                            ytDlpPath: ytDlpPath,
                            itemStorageKey: itemStorageKey,
                            attachmentStorageKey: attachmentStorageKey,
                            outputURL: outputURL,
                            transcriptAlreadyExists: transcriptAlreadyExists
                        )
                    }
                    return
                } catch {
                    Log.error(Log.chapters, "Failed to save native chapters: \(error)")
                }
            }
        }

        // Phase 2: AI structural sections from transcript
        await generateAIContent(
            videoId: videoId,
            ytDlpPath: ytDlpPath,
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attachmentStorageKey,
            outputURL: outputURL,
            duration: duration,
            transcriptAlreadyExists: transcriptAlreadyExists,
            mode: mode
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

    // MARK: - Enrich Native Chapters with AI Summaries

    private static let enrichmentPrompt = """
    You are given a video transcript and a list of chapter markers with titles. \
    For each chapter, write a 1-2 sentence summary that captures the key point discussed in that section. \
    Write in the same voice and tone as the speakers.

    ## Input

    The user message contains the transcript. The chapter list is below:

    CHAPTERS_PLACEHOLDER

    ## Output Format

    Output ONLY a JSON array with the same chapters, adding a "summary" field to each. \
    Keep startTime and title exactly as given. No markdown fences:

    [{"startTime": <seconds>, "title": "...", "summary": "..."}]
    """

    private func enrichChaptersWithSummaries(
        chapterData: ChapterData,
        videoId: String,
        ytDlpPath: String,
        itemStorageKey: String,
        attachmentStorageKey: String,
        outputURL: URL,
        transcriptAlreadyExists: Bool
    ) async {
        // Load transcript
        let transcriptURL = CatalogDatabase.attachmentTranscriptURL(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attachmentStorageKey
        )

        var transcriptText: String?
        if transcriptAlreadyExists || FileManager.default.fileExists(atPath: transcriptURL.path) {
            transcriptText = try? String(contentsOf: transcriptURL, encoding: .utf8)
        }
        if transcriptText == nil || transcriptText!.isEmpty {
            transcriptText = await fetchTranscript(videoId: videoId, ytDlpPath: ytDlpPath, saveURL: transcriptURL)
        }

        guard let transcript = transcriptText, !transcript.isEmpty else {
            Log.info(Log.chapters, "No transcript available for chapter enrichment")
            return
        }

        let prefs = Preferences.shared
        let pid = prefs.youtubeAIProviderId
        let config = ProviderConfig(
            providerId: pid,
            model: prefs.youtubeAIModel.isEmpty ? (ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? "") : prefs.youtubeAIModel
        )
        let router = ProviderRouter()
        guard let provider = try? router.provider(for: config) else { return }

        Log.info(Log.chapters, "Enriching \(chapterData.chapters.count) native chapters with AI summaries")

        // Build chapter list for the prompt
        let chapterList = chapterData.chapters.map { ch in
            "- [\(MediaViewModel.formatTimestamp(seconds: ch.startTime, bracketed: false))] \(ch.title)"
        }.joined(separator: "\n")

        let systemPrompt = Self.enrichmentPrompt
            .replacingOccurrences(of: "CHAPTERS_PLACEHOLDER", with: chapterList)

        let truncated = String(transcript.prefix(120_000))
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
                case .delta(let text): fullResponse += text
                case .toolUse: break
                case .finished: break
                case .error(let msg):
                    Log.error(Log.chapters, "Enrichment AI error: \(msg)")
                    return
                }
            }
        } catch {
            Log.error(Log.chapters, "Chapter enrichment failed: \(error)")
            return
        }

        guard let enriched = parseAIResponse(fullResponse, duration: chapterData.videoDuration) else {
            Log.error(Log.chapters, "Failed to parse enrichment response")
            return
        }

        // Merge summaries back into original chapters (match by startTime proximity)
        var updated = chapterData.chapters
        for (i, original) in updated.enumerated() {
            if let match = enriched.first(where: { abs($0.startTime - original.startTime) < 10 }),
               let summary = match.summary, !summary.isEmpty {
                updated[i] = VideoChapter(
                    id: original.id,
                    startTime: original.startTime,
                    endTime: original.endTime,
                    title: original.title,
                    summary: summary
                )
            }
        }

        let enrichedData = ChapterData(
            version: chapterData.version,
            generatedAt: chapterData.generatedAt,
            videoDuration: chapterData.videoDuration,
            source: chapterData.source,
            modelUsed: config.model,
            chapters: updated
        )

        do {
            try enrichedData.save(to: outputURL)
            Log.info(Log.chapters, "Enriched \(updated.filter { $0.summary != nil }.count) chapters with summaries")
        } catch {
            Log.error(Log.chapters, "Failed to save enriched chapters: \(error)")
        }
    }

    /// Run `yt-dlp -j --no-download` and return the parsed JSON dictionary.
    private func runYtDlpMetadata(videoId: String, ytDlpPath: String) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            Task.detached {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("oakreader-ytdlp-metadata-\(UUID().uuidString)")
                let outputURL = tempDir.appendingPathComponent("metadata.json")
                let errorURL = tempDir.appendingPathComponent("stderr.log")

                do {
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                } catch {
                    Log.error(Log.chapters, "Could not create yt-dlp temp directory: \(error)")
                    continuation.resume(returning: nil)
                    return
                }
                defer { try? FileManager.default.removeItem(at: tempDir) }

                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                FileManager.default.createFile(atPath: errorURL.path, contents: nil)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: ytDlpPath)
                process.arguments = [
                    "-j",
                    "--no-download",
                    "https://www.youtube.com/watch?v=\(videoId)",
                ]

                guard let outputHandle = try? FileHandle(forWritingTo: outputURL),
                      let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
                    Log.error(Log.chapters, "Could not open yt-dlp output files")
                    continuation.resume(returning: nil)
                    return
                }
                defer {
                    outputHandle.closeFile()
                    errorHandle.closeFile()
                }

                process.standardOutput = outputHandle
                process.standardError = errorHandle

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in semaphore.signal() }

                do {
                    try process.run()
                } catch {
                    Log.error(Log.chapters, "yt-dlp metadata process failed: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                guard Self.waitForProcess(
                    process,
                    semaphore: semaphore,
                    timeout: Self.ytDlpMetadataTimeout,
                    label: "yt-dlp metadata"
                ) else {
                    Log.error(Log.chapters, "yt-dlp metadata timed out after \(Int(Self.ytDlpMetadataTimeout))s")
                    continuation.resume(returning: nil)
                    return
                }
                outputHandle.synchronizeFile()
                errorHandle.synchronizeFile()

                guard process.terminationStatus == 0 else {
                    let stderr = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
                    Log.error(Log.chapters, "yt-dlp metadata exited with status \(process.terminationStatus): \(stderr.prefix(300))")
                    continuation.resume(returning: nil)
                    return
                }

                guard let data = try? Data(contentsOf: outputURL) else {
                    continuation.resume(returning: nil)
                    return
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: json)
            }
        }
    }

    // MARK: - Phase 2: AI Content Generation

    private func generateAIContent(
        videoId: String,
        ytDlpPath: String,
        itemStorageKey: String,
        attachmentStorageKey: String,
        outputURL: URL,
        duration: Int?,
        transcriptAlreadyExists: Bool,
        mode: ChapterGenerationMode
    ) async {
        // Guard: skip for very short videos
        if let duration, duration < 180 {
            Log.info(Log.chapters, "Video too short (\(duration)s) for AI \(mode == .chapters ? "chapters" : "highlights"), skipping")
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
            Log.info(Log.chapters, "No transcript available for AI generation")
            return
        }

        // Check for AI API key
        let prefs = Preferences.shared
        let pid = prefs.youtubeAIProviderId
        let config = ProviderConfig(
            providerId: pid,
            model: prefs.youtubeAIModel.isEmpty ? (ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? "") : prefs.youtubeAIModel
        )

        let router = ProviderRouter()
        guard let provider = try? router.provider(for: config) else {
            Log.info(Log.chapters, "No AI API key configured, skipping AI generation")
            return
        }

        let label = mode == .chapters ? "sections" : "highlights"
        let providerName = ProviderRegistry.shared.provider(for: config.providerId)?.displayName ?? config.providerId
        Log.info(Log.chapters, "Generating AI \(label) using \(providerName) / \(config.model)")

        let systemPrompt: String
        switch mode {
        case .chapters:
            systemPrompt = Self.loadSectionPrompt()
        case .highlights:
            systemPrompt = Self.loadChapterPrompt()
        }

        // Split long transcripts into chunks, generate for each, then merge
        let maxChunkSize = 120_000
        var allChapters: [VideoChapter] = []

        if transcript.count <= maxChunkSize {
            // Single pass for transcripts within limit
            if let chapters = await generateFromChunk(
                transcript: transcript,
                systemPrompt: systemPrompt,
                provider: provider,
                config: config,
                duration: duration,
                label: label
            ) {
                allChapters = chapters
            }
        } else {
            // Split transcript into overlapping chunks by line
            let chunks = Self.splitTranscript(transcript, maxChunkSize: maxChunkSize)
            Log.info(Log.chapters, "Transcript too long (\(transcript.count) chars), splitting into \(chunks.count) chunks")

            for (index, chunk) in chunks.enumerated() {
                Log.info(Log.chapters, "Processing chunk \(index + 1)/\(chunks.count)")
                if let chapters = await generateFromChunk(
                    transcript: chunk,
                    systemPrompt: systemPrompt,
                    provider: provider,
                    config: config,
                    duration: duration,
                    label: label
                ) {
                    allChapters.append(contentsOf: chapters)
                }
            }

            // Deduplicate by removing overlapping entries (within 30s of each other)
            allChapters.sort { $0.startTime < $1.startTime }
            allChapters = Self.deduplicateChapters(allChapters, threshold: 30)
        }

        guard !allChapters.isEmpty else {
            Log.error(Log.chapters, "AI \(label) generation produced no results")
            return
        }

        let chapterData = ChapterData(
            version: 1,
            generatedAt: Date().iso8601String,
            videoDuration: duration,
            source: .ai,
            modelUsed: config.model,
            chapters: allChapters
        )

        do {
            try chapterData.save(to: outputURL)
            Log.info(Log.chapters, "Saved \(allChapters.count) AI-generated \(label)")
        } catch {
            Log.error(Log.chapters, "Failed to save AI \(label): \(error)")
        }
    }

    private func generateFromChunk(
        transcript: String,
        systemPrompt: String,
        provider: any LLMProviderService,
        config: ProviderConfig,
        duration: Int?,
        label: String
    ) async -> [VideoChapter]? {
        let messages = [LLMMessage(role: .user, text: transcript)]

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
                case .toolUse:
                    break
                case .finished:
                    break
                case .error(let msg):
                    Log.error(Log.chapters, "AI stream error: \(msg)")
                    return nil
                }
            }
        } catch {
            Log.error(Log.chapters, "AI \(label) generation failed: \(error)")
            return nil
        }

        guard !fullResponse.isEmpty else {
            Log.error(Log.chapters, "AI returned empty response")
            return nil
        }

        return parseAIResponse(fullResponse, duration: duration)
    }

    /// Split transcript into chunks at line boundaries, with a small overlap.
    private static func splitTranscript(_ transcript: String, maxChunkSize: Int) -> [String] {
        let lines = transcript.components(separatedBy: .newlines)
        var chunks: [String] = []
        var currentLines: [String] = []
        var currentSize = 0
        let overlapLines = 20 // ~20 lines overlap for context

        for line in lines {
            let lineSize = line.count + 1 // +1 for newline
            if currentSize + lineSize > maxChunkSize, !currentLines.isEmpty {
                chunks.append(currentLines.joined(separator: "\n"))
                // Keep last N lines as overlap for next chunk
                let overlapStart = max(0, currentLines.count - overlapLines)
                currentLines = Array(currentLines[overlapStart...])
                currentSize = currentLines.reduce(0) { $0 + $1.count + 1 }
            }
            currentLines.append(line)
            currentSize += lineSize
        }

        if !currentLines.isEmpty {
            chunks.append(currentLines.joined(separator: "\n"))
        }

        return chunks
    }

    /// Remove duplicate chapters that are within `threshold` seconds of each other.
    private static func deduplicateChapters(_ chapters: [VideoChapter], threshold: Double) -> [VideoChapter] {
        var result: [VideoChapter] = []
        for chapter in chapters {
            if let last = result.last, abs(chapter.startTime - last.startTime) < threshold {
                continue // skip duplicate
            }
            result.append(chapter)
        }
        return result
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
                guard let nullOutput = Self.nullWriteHandle(),
                      let nullError = Self.nullWriteHandle() else {
                    continuation.resume(returning: nil)
                    return
                }
                defer {
                    nullOutput.closeFile()
                    nullError.closeFile()
                }
                process.standardOutput = nullOutput
                process.standardError = nullError

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in semaphore.signal() }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                guard Self.waitForProcess(
                    process,
                    semaphore: semaphore,
                    timeout: Self.ytDlpTranscriptTimeout,
                    label: "yt-dlp transcript"
                ) else {
                    Log.error(Log.chapters, "yt-dlp transcript timed out after \(Int(Self.ytDlpTranscriptTimeout))s")
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

    private static func waitForProcess(
        _ process: Process,
        semaphore: DispatchSemaphore,
        timeout: TimeInterval,
        label: String
    ) -> Bool {
        if semaphore.wait(timeout: .now() + timeout) == .success {
            return true
        }

        if process.isRunning {
            process.terminate()
        }

        if semaphore.wait(timeout: .now() + 2) == .success {
            return false
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _ = semaphore.wait(timeout: .now() + 2)
        Log.error(Log.chapters, "\(label) required SIGKILL after timeout")
        return false
    }

    private static func nullWriteHandle() -> FileHandle? {
        try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
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
            let endTime: Double?
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
            if let itemEndTime = item.endTime, itemEndTime > item.startTime {
                endTime = itemEndTime
            } else if index + 1 < raw.count {
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

    private static let defaultSectionPrompt = """
    You are an expert video editor creating chapter markers. Given a timestamped transcript, \
    divide the video into logical sections that help a viewer navigate the content.

    ## Rules

    - Chapters must cover the ENTIRE video with no gaps — every second belongs to a chapter.
    - First chapter MUST start at 0:00.
    - Each chapter covers approximately 3-10 minutes of content.
    - Align chapter boundaries with natural topic transitions, not mid-sentence.
    - Titles must be specific and descriptive, 4-8 words. Name the actual topic, not "Discussion" or "Segment 3".
    - Each chapter MUST include a 1-2 sentence summary that captures the key point or argument made in that section. \
    Write summaries in the same voice and register as the speakers — if the conversation is casual, the summary should be too.
    - Short videos (<15 min): 3-5 chapters.
    - Medium videos (15-60 min): 6-12 chapters.
    - Long videos (60+ min): 12-20 chapters.
    - Use transcript timestamps. `startTime` is in seconds.

    ## Output Format

    Output ONLY a JSON array, no markdown fences:

    [{"startTime": <seconds>, "title": "...", "summary": "..."}]
    """

    static let defaultHighlightPrompt = """
    You are an expert video highlight editor. Given a timestamped transcript, \
    select the moments a viewer would most want to revisit, clip, quote, or save.

    Your job is NOT to make a full outline. Do not cover the whole video. \
    Find the densest, most useful, surprising, memorable, or decision-changing moments.

    ## Rules

    - Select highlights, not chapters.
    - A highlight should be self-contained and worth jumping to directly.
    - Prefer concrete claims, strong opinions, demos, technical explanations, decisions, tradeoffs, examples, stories, warnings, and memorable quotes.
    - Skip intros, outros, sponsorships, greetings, setup, filler, repeated points, and generic transitions.
    - Each highlight should usually be 20-120 seconds long.
    - Leave gaps between highlights when the content is not highlight-worthy.
    - Titles must be specific and editorial, 4-10 words.
    - Summaries must explain why this moment matters in one concise sentence.
    - Short videos (<15 min): 3-6 highlights.
    - Medium videos (15-60 min): 6-12 highlights.
    - Long videos (60+ min): 8-16 highlights.
    - Use transcript timestamps. `startTime` and `endTime` are seconds.
    - `endTime` must be greater than `startTime`.

    ## Output Format

    Output ONLY a JSON array, no markdown fences:

    [{"startTime": <seconds>, "endTime": <seconds>, "title": "...", "summary": "..."}]
    """

    static func loadChapterPrompt() -> String {
        let url = Preferences.chapterPromptURL
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8),
           !content.isEmpty {
            if content.trimmingCharacters(in: .whitespacesAndNewlines)
                == defaultSectionPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                try? defaultHighlightPrompt.write(to: url, atomically: true, encoding: .utf8)
                return defaultHighlightPrompt
            }
            return content
        }

        // Create default prompt file
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? defaultHighlightPrompt.write(to: url, atomically: true, encoding: .utf8)
        return defaultHighlightPrompt
    }

    static func loadSectionPrompt() -> String {
        let url = Preferences.sectionPromptURL
        let fm = FileManager.default

        if fm.fileExists(atPath: url.path),
           let content = try? String(contentsOf: url, encoding: .utf8),
           !content.isEmpty {
            return content
        }

        // Create default section prompt file
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? defaultSectionPrompt.write(to: url, atomically: true, encoding: .utf8)
        return defaultSectionPrompt
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
