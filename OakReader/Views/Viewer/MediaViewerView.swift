import SwiftUI
import WebKit
import YouTubePlayerKit
import YoutubeTranscript
import OakReaderAI
import Darwin

/// A single timestamped line in the transcript.
struct TranscriptEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let offset: Double
    let text: String
}

struct MediaSeekRequest: Equatable {
    let id = UUID()
    let seconds: Double
}

@Observable
final class MediaViewModel {
    weak var parent: DocumentViewModel?

    var transcriptEntries: [TranscriptEntry] = []
    var transcriptText: String?
    var activeEntryID: Int?
    var isLoadingTranscript = false
    var transcriptErrorMessage: String?

    var chapters: [VideoChapter] = []
    var chapterSource: ChapterSource?
    var chapterStatus: ChapterGenerationStatus = .idle
    var activeChapterID: UUID?

    var highlights: [VideoChapter] = []
    var highlightStatus: ChapterGenerationStatus = .idle
    var activeHighlightID: UUID?

    var currentPlaybackTime: Double = 0
    var seekRequest: MediaSeekRequest?

    private var mediaKey: URL?
    private var transcriptLoadedKey: URL?
    private var transcriptLoadingKey: URL?
    private var chaptersLoadedKey: URL?
    private var chaptersLoadingKey: URL?
    private var highlightsLoadedKey: URL?
    private var highlightsLoadingKey: URL?

    private static let ytDlpTranscriptTimeout: TimeInterval = 45

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    func prepareForMedia(_ media: MediaDocument) {
        guard mediaKey != media.storageDirectory else { return }
        mediaKey = media.storageDirectory
        transcriptEntries = []
        transcriptText = nil
        activeEntryID = nil
        isLoadingTranscript = false
        transcriptErrorMessage = nil
        chapters = []
        chapterSource = nil
        chapterStatus = .idle
        activeChapterID = nil
        highlights = []
        highlightStatus = .idle
        activeHighlightID = nil
        currentPlaybackTime = parent?.lastPlaybackTime ?? parent?.libraryItem?.lastPosition ?? 0
        transcriptLoadedKey = nil
        transcriptLoadingKey = nil
        chaptersLoadedKey = nil
        chaptersLoadingKey = nil
        highlightsLoadedKey = nil
        highlightsLoadingKey = nil
    }

    func requestSeek(seconds: Double) {
        let clampedSeconds = max(0, seconds)
        seekRequest = MediaSeekRequest(seconds: clampedSeconds)
        updatePlaybackTime(clampedSeconds)
    }

    func updatePlaybackTime(_ seconds: Double) {
        currentPlaybackTime = max(0, seconds)

        let nextEntryID = transcriptEntries.last(where: { $0.offset <= currentPlaybackTime })?.id
        if nextEntryID != activeEntryID {
            activeEntryID = nextEntryID
        }

        let nextChapterID = activeItemID(at: currentPlaybackTime, in: chapters)
        if nextChapterID != activeChapterID {
            activeChapterID = nextChapterID
        }

        let nextHighlightID = activeItemID(at: currentPlaybackTime, in: highlights)
        if nextHighlightID != activeHighlightID {
            activeHighlightID = nextHighlightID
        }
    }

    private func activeItemID(at seconds: Double, in items: [VideoChapter]) -> UUID? {
        for (index, item) in items.enumerated() where item.startTime <= seconds {
            let inferredEnd = item.endTime
                ?? (items.indices.contains(index + 1) ? items[index + 1].startTime : nil)
            guard let inferredEnd else { return item.id }
            if seconds < inferredEnd {
                return item.id
            }
        }
        return nil
    }

    func loadOrFetchTranscript(media: MediaDocument) async {
        prepareForMedia(media)
        let key = media.storageDirectory
        guard transcriptLoadedKey != key, transcriptLoadingKey != key else { return }
        transcriptLoadingKey = key
        defer { transcriptLoadingKey = nil }

        transcriptErrorMessage = nil

        if let url = media.transcriptURL,
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            let parsed = Self.parseTranscriptText(text)
            if !parsed.isEmpty {
                transcriptEntries = parsed
            } else {
                transcriptText = text
            }
            transcriptLoadedKey = key
            updatePlaybackTime(currentPlaybackTime)
            return
        }

        guard let videoId = Self.extractYouTubeVideoId(from: media.sourceURL) else {
            transcriptLoadedKey = key
            return
        }

        isLoadingTranscript = true
        defer { isLoadingTranscript = false }

        do {
            let ytDlpPath = Preferences.shared.ytDlpPath
            var entries: [TranscriptEntry] = []

            if !ytDlpPath.isEmpty, FileManager.default.isExecutableFile(atPath: ytDlpPath) {
                entries = await Self.fetchTranscriptViaYtDlp(videoId: videoId, ytDlpPath: ytDlpPath)
            }

            if entries.isEmpty {
                do {
                    let responses = try await YoutubeTranscript.fetchTranscript(for: videoId)
                    entries = responses.enumerated().map { index, response in
                        TranscriptEntry(id: index, offset: response.offset, text: response.text)
                    }
                } catch {
                    if ytDlpPath.isEmpty {
                        throw error
                    }
                    throw error
                }
            }

            guard !entries.isEmpty else {
                transcriptErrorMessage = "No transcript is available for this video."
                transcriptLoadedKey = key
                return
            }

            transcriptEntries = entries
            transcriptLoadedKey = key
            updatePlaybackTime(currentPlaybackTime)

            let formatted = entries.map { entry in
                "\(Self.formatTimestamp(seconds: entry.offset)) \(entry.text)"
            }.joined(separator: "\n")
            let fileURL = media.storageDirectory.appendingPathComponent("transcript.txt")
            try? formatted.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            let ytDlpPath = Preferences.shared.ytDlpPath
            if ytDlpPath.isEmpty {
                transcriptErrorMessage = "\(error.localizedDescription)\n\nTip: Install yt-dlp for more reliable transcripts (Settings > YouTube)."
            } else {
                transcriptErrorMessage = error.localizedDescription
            }
        }
    }

    func retryTranscript(media: MediaDocument) {
        transcriptLoadedKey = nil
        transcriptErrorMessage = nil
        Task { await loadOrFetchTranscript(media: media) }
    }

    func loadChapters(media: MediaDocument) async {
        prepareForMedia(media)
        let key = media.storageDirectory
        guard chaptersLoadedKey != key, chaptersLoadingKey != key else { return }
        chaptersLoadingKey = key
        defer { chaptersLoadingKey = nil }

        let chaptersFileURL = media.storageDirectory.appendingPathComponent("chapters.json")
        if let data = ChapterData.load(from: chaptersFileURL) {
            chapters = data.chapters
            chapterSource = data.source
            chapterStatus = .completed(data.source)
            chaptersLoadedKey = key
            updatePlaybackTime(currentPlaybackTime)
            return
        }

        if chapterStatus == .idle {
            chapterStatus = .extractingChapters
        }

        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }

            if let data = ChapterData.load(from: chaptersFileURL) {
                chapters = data.chapters
                chapterSource = data.source
                chapterStatus = .completed(data.source)
                chaptersLoadedKey = key
                updatePlaybackTime(currentPlaybackTime)
                return
            }
        }

        if case .extractingChapters = chapterStatus {
            chapterStatus = .idle
        }
        chaptersLoadedKey = key
    }

    func generateChaptersManually(media: MediaDocument) async {
        prepareForMedia(media)
        chapterStatus = .generatingChapters
        chaptersLoadedKey = nil

        guard let item = parent?.libraryItem,
              let attachment = item.primaryAttachment else {
            chapterStatus = .failed("Could not determine storage location")
            return
        }

        let service = ChapterGenerationService()
        await service.run(
            itemStorageKey: item.storageKey,
            attachmentStorageKey: attachment.storageKey,
            sourceURL: media.sourceURL,
            duration: media.metadata.duration,
            transcriptAlreadyExists: media.transcriptURL != nil || !transcriptEntries.isEmpty || transcriptText != nil,
            tryNativeChapters: false,
            mode: .chapters
        )

        let chaptersFileURL = media.storageDirectory.appendingPathComponent("chapters.json")
        if let data = ChapterData.load(from: chaptersFileURL) {
            chapters = data.chapters
            chapterSource = data.source
            chapterStatus = .completed(data.source)
            chaptersLoadedKey = media.storageDirectory
            updatePlaybackTime(currentPlaybackTime)
        } else {
            chapterStatus = .failed("Chapter generation did not produce results")
        }
    }

    // MARK: - Highlights

    func loadHighlights(media: MediaDocument) async {
        prepareForMedia(media)
        let key = media.storageDirectory
        guard highlightsLoadedKey != key, highlightsLoadingKey != key else { return }
        highlightsLoadingKey = key
        defer { highlightsLoadingKey = nil }

        let highlightsFileURL = media.storageDirectory.appendingPathComponent("highlights.json")
        if let data = ChapterData.load(from: highlightsFileURL) {
            highlights = data.chapters
            highlightStatus = .completed(data.source)
            highlightsLoadedKey = key
            updatePlaybackTime(currentPlaybackTime)
            return
        }

        // Poll briefly in case highlights are being generated by import
        if highlightStatus == .idle {
            highlightStatus = .extractingChapters
        }

        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }

            if let data = ChapterData.load(from: highlightsFileURL) {
                highlights = data.chapters
                highlightStatus = .completed(data.source)
                highlightsLoadedKey = key
                updatePlaybackTime(currentPlaybackTime)
                return
            }
        }

        // No highlights found — auto-generate if AI key is available
        guard !Task.isCancelled else { return }
        if KeychainService.apiKey(for: Preferences.shared.youtubeAIProvider) != nil {
            highlightsLoadingKey = nil // allow generateHighlightsManually to proceed
            await generateHighlightsManually(media: media)
            return
        }

        if case .extractingChapters = highlightStatus {
            highlightStatus = .idle
        }
        highlightsLoadedKey = key
    }

    func generateHighlightsManually(media: MediaDocument) async {
        prepareForMedia(media)
        highlightStatus = .generatingChapters
        highlightsLoadedKey = nil

        guard let item = parent?.libraryItem,
              let attachment = item.primaryAttachment else {
            highlightStatus = .failed("Could not determine storage location")
            return
        }

        let service = ChapterGenerationService()
        await service.run(
            itemStorageKey: item.storageKey,
            attachmentStorageKey: attachment.storageKey,
            sourceURL: media.sourceURL,
            duration: media.metadata.duration,
            transcriptAlreadyExists: media.transcriptURL != nil || !transcriptEntries.isEmpty || transcriptText != nil,
            tryNativeChapters: false,
            mode: .highlights
        )

        let highlightsFileURL = media.storageDirectory.appendingPathComponent("highlights.json")
        if let data = ChapterData.load(from: highlightsFileURL) {
            highlights = data.chapters
            highlightStatus = .completed(data.source)
            highlightsLoadedKey = media.storageDirectory
            updatePlaybackTime(currentPlaybackTime)
        } else {
            highlightStatus = .failed("Highlight generation did not produce results")
        }
    }

    static func extractYouTubeVideoId(from url: URL) -> String? {
        let urlString = url.absoluteString
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let vParam = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return vParam
        }
        if url.host == "youtu.be" {
            return url.pathComponents.last
        }
        if urlString.contains("/embed/") {
            return url.pathComponents.last
        }
        return nil
    }

    static func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func formatTimestamp(seconds: Double, bracketed: Bool = true) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        let value: String
        if h > 0 {
            value = String(format: "%d:%02d:%02d", h, m, s)
        } else {
            value = String(format: "%d:%02d", m, s)
        }
        return bracketed ? "[\(value)]" : value
    }

    static func chapterDurationLabel(for chapter: VideoChapter, nextChapter: VideoChapter?, mediaDuration: Int?) -> String? {
        let endTime = chapter.endTime ?? nextChapter?.startTime ?? mediaDuration.map(Double.init)
        guard let endTime, endTime > chapter.startTime else { return nil }
        return formatDuration(Int(endTime - chapter.startTime))
    }

    private static func fetchTranscriptViaYtDlp(videoId: String, ytDlpPath: String) async -> [TranscriptEntry] {
        await withCheckedContinuation { continuation in
            Task.detached {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("oakreader-transcript-\(videoId)-\(UUID().uuidString)")

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
                    continuation.resume(returning: [])
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
                    continuation.resume(returning: [])
                    return
                }

                guard Self.waitForProcess(
                    process,
                    semaphore: semaphore,
                    timeout: Self.ytDlpTranscriptTimeout
                ) else {
                    continuation.resume(returning: [])
                    return
                }

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: [])
                    return
                }

                let files = (try? FileManager.default.contentsOfDirectory(
                    at: tempDir,
                    includingPropertiesForKeys: nil
                )) ?? []
                guard let subFile = files.first(where: { $0.pathExtension == "json3" }),
                      let data = try? Data(contentsOf: subFile) else {
                    continuation.resume(returning: [])
                    return
                }

                continuation.resume(returning: Self.parseJSON3Subtitles(data))
            }
        }
    }

    private static func parseJSON3Subtitles(_ data: Data) -> [TranscriptEntry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else {
            return []
        }

        var entries: [TranscriptEntry] = []
        for event in events {
            guard let tStartMs = event["tStartMs"] as? Double,
                  let segs = event["segs"] as? [[String: Any]] else {
                continue
            }

            let text = segs.compactMap { $0["utf8"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "\n" else { continue }

            entries.append(TranscriptEntry(
                id: entries.count,
                offset: tStartMs / 1000.0,
                text: text
            ))
        }

        return entries
    }

    private static func parseTranscriptText(_ text: String) -> [TranscriptEntry] {
        let pattern = /^\[(?:(\d+):)?(\d+):(\d{2})\]\s+(.+)$/
        var entries: [TranscriptEntry] = []

        for line in text.components(separatedBy: .newlines) {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let hours = match.output.1.flatMap { Double($0) } ?? 0
            let minutes = Double(match.output.2) ?? 0
            let seconds = Double(match.output.3) ?? 0
            let offset = hours * 3600 + minutes * 60 + seconds
            entries.append(TranscriptEntry(id: entries.count, offset: offset, text: String(match.output.4)))
        }

        return entries
    }

    private static func waitForProcess(
        _ process: Process,
        semaphore: DispatchSemaphore,
        timeout: TimeInterval
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
        return false
    }

    private static func nullWriteHandle() -> FileHandle? {
        try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
    }
}

enum MediaChapterPalette {
    static let accent = Color.accentColor

    static func color(for _: Int) -> Color {
        accent
    }
}

struct MediaChapterTimelineView: View {
    let chapters: [VideoChapter]
    let duration: Double?
    let currentTime: Double
    var compact = false
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.06))

                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    let start = clampedRatio(chapter.startTime)
                    let end = clampedRatio(endTime(for: index))
                    let width = max((end - start) * geometry.size.width, compact ? 5 : 8)

                    Button {
                        onSeek(chapter.startTime)
                    } label: {
                        RoundedRectangle(cornerRadius: compact ? 4 : 8, style: .continuous)
                            .fill(MediaChapterPalette.color(for: index).opacity(compact ? 0.45 : 0.35))
                            .frame(width: width, height: compact ? 16 : 28)
                    }
                    .buttonStyle(.plain)
                    .offset(x: start * geometry.size.width)
                    .help(chapter.title)
                }

                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.red)
                    .frame(width: 2, height: compact ? 22 : 36)
                    .offset(x: min(max(clampedRatio(currentTime) * geometry.size.width - 1, 0), max(geometry.size.width - 2, 0)))
            }
        }
        .frame(height: compact ? 24 : 44)
    }

    private var timelineDuration: Double {
        let knownDuration = duration ?? 0
        let chapterDuration = chapters.indices.map { endTime(for: $0) }.max() ?? 0
        return max(knownDuration, chapterDuration, 1)
    }

    private func endTime(for index: Int) -> Double {
        let chapter = chapters[index]
        if let endTime = chapter.endTime, endTime > chapter.startTime {
            return endTime
        }
        if chapters.indices.contains(index + 1) {
            return max(chapters[index + 1].startTime, chapter.startTime + 1)
        }
        if let duration, duration > chapter.startTime {
            return duration
        }
        return chapter.startTime + 1
    }

    private func clampedRatio(_ seconds: Double) -> CGFloat {
        CGFloat(min(max(seconds / timelineDuration, 0), 1))
    }
}

/// Viewer for embed documents (YouTube).
struct MediaViewerView: View {
    let viewModel: DocumentViewModel

    @State private var youtubePlayer: YouTubePlayer?
    @State private var contextMenuHandler: MediaContextMenuHandler?

    var body: some View {
        if let media = viewModel.mediaDocument {
            GeometryReader { geometry in
                let totalHeight = geometry.size.height
                let topHeight = totalHeight * 0.7
                let bottomHeight = totalHeight * 0.3
                let maxVideoWidth = max(geometry.size.width - 32, 280)
                let videoWidth = min(maxVideoWidth, (topHeight - 40) * 16 / 9, 1120)

                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        youtubeEmbed(media: media)
                            .frame(width: videoWidth)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .cornerRadius(8)

                        metadataSection(media: media)
                            .frame(width: videoWidth)
                    }
                    .frame(height: topHeight)

                    chapterReelSection(media: media)
                        .frame(width: videoWidth, height: bottomHeight)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(OakStyle.Colors.contentBackground)
            .task(id: media.storageDirectory) {
                viewModel.media.prepareForMedia(media)
                await viewModel.media.loadOrFetchTranscript(media: media)
            }
            .task(id: media.storageDirectory.appendingPathComponent("chapters.json")) {
                await viewModel.media.loadChapters(media: media)
            }
            .task(id: media.storageDirectory.appendingPathComponent("highlights.json")) {
                await viewModel.media.loadHighlights(media: media)
            }
            .task(id: youtubePlayer != nil) {
                await trackPlayback()
            }
            .onChange(of: viewModel.media.seekRequest?.id) { _, _ in
                guard let request = viewModel.media.seekRequest else { return }
                seekTo(seconds: request.seconds)
            }
            .onAppear {
                configurePlayerIfNeeded(media: media)
                let handler = MediaContextMenuHandler(viewModel: viewModel)
                handler.install()
                contextMenuHandler = handler
            }
            .onDisappear {
                contextMenuHandler?.remove()
                contextMenuHandler = nil
                guard let player = youtubePlayer else { return }
                Task { @MainActor in
                    guard let time = try? await player.getCurrentTime() else { return }
                    let seconds = time.converted(to: .seconds).value
                    viewModel.lastPlaybackTime = seconds
                    viewModel.media.updatePlaybackTime(seconds)
                    if let item = viewModel.libraryItem {
                        viewModel.libraryStore?.updateLastPosition(item, position: seconds)
                    }
                }
            }
        } else {
            Text("No media loaded")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func youtubeEmbed(media: MediaDocument) -> some View {
        if let player = youtubePlayer {
            YouTubePlayerView(player) { state in
                switch state {
                case .idle:
                    videoLoadingState
                case .ready:
                    EmptyView()
                case .error:
                    videoErrorState
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
        } else {
            videoLoadingState
                .aspectRatio(16 / 9, contentMode: .fit)
        }
    }

    private var videoLoadingState: some View {
        ZStack {
            Color.black
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    private var videoErrorState: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.gray)
                Text("Failed to load video")
                    .foregroundStyle(.gray)
            }
        }
    }

    @ViewBuilder
    private func metadataSection(media: MediaDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(media.metadata.title)
                .font(.headline.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(media.metadata.author)

                if let duration = media.metadata.duration {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(MediaViewModel.formatDuration(duration))
                }

                if let publishedAt = media.metadata.publishedAt {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(publishedAt)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func chapterReelSection(media: MediaDocument) -> some View {
        let model = viewModel.media

        if !model.highlights.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("AI Highlights")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    if let duration = media.metadata.duration {
                        let currentTime = MediaViewModel.formatTimestamp(
                            seconds: model.currentPlaybackTime,
                            bracketed: false
                        )
                        let totalTime = MediaViewModel.formatDuration(duration)
                        Text("\(currentTime) / \(totalTime)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                ZoomableChapterTimelineView(
                    chapters: model.highlights,
                    duration: media.metadata.duration.map(Double.init) ?? 0,
                    currentTime: model.currentPlaybackTime,
                    activeChapterID: model.activeHighlightID,
                    onSeek: { seconds in seekTo(seconds: seconds) }
                )

                ScrollViewReader { proxy in
                    ScrollView {
                        highlightCardList(media: media, model: model)
                    }
                    .onChange(of: model.activeHighlightID) { _, newID in
                        guard let id = newID else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            switch model.highlightStatus {
            case .extractingChapters:
                reelStatusRow(message: "Checking for highlights...")
            case .fetchingTranscript:
                reelStatusRow(message: "Fetching transcript...")
            case .generatingChapters:
                reelStatusRow(message: "Finding highlights...")
            case .failed(let message):
                reelErrorRow(message: message, media: media)
            case .skipped(let reason):
                reelIdleRow(message: reason, media: media)
            case .completed:
                reelIdleRow(message: "No highlights are available for this video.", media: media)
            case .idle:
                reelIdleRow(message: "No highlights yet.", media: media)
            }
        }
    }


    private func highlightCardList(media: MediaDocument, model: MediaViewModel) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(model.highlights) { highlight in
                let active = model.activeHighlightID == highlight.id
                Button {
                    seekTo(seconds: highlight.startTime)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Text(MediaViewModel.formatTimestamp(seconds: highlight.startTime, bracketed: false))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(active ? .primary : .secondary)
                            .frame(width: 38, alignment: .trailing)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(highlight.title)
                                .font(.body.bold())
                                .foregroundStyle(.primary)

                            if let summary = highlight.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(active ? Color.accentColor.opacity(0.08) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .id(highlight.id)
            }
        }
    }

    private func reelStatusRow(message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func reelErrorRow(message: String, media: MediaDocument) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            generateOutlineButton(media: media, title: "Retry")
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func reelIdleRow(message: String, media: MediaDocument) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if KeychainService.apiKey(for: Preferences.shared.youtubeAIProvider) != nil {
                generateOutlineButton(media: media, title: "Find AI Highlights")
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func generateOutlineButton(media: MediaDocument, title: String) -> some View {
        Button {
            Task { await viewModel.media.generateHighlightsManually(media: media) }
        } label: {
            Label(title, systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func configurePlayerIfNeeded(media: MediaDocument) {
        guard youtubePlayer == nil,
              let videoId = MediaViewModel.extractYouTubeVideoId(from: media.sourceURL) else {
            return
        }

        let savedTime = viewModel.lastPlaybackTime ?? viewModel.libraryItem?.lastPosition
        var params = YouTubePlayer.Parameters(autoPlay: false)
        if let savedTime, savedTime > 0 {
            params.startTime = .init(value: savedTime, unit: .seconds)
            viewModel.media.updatePlaybackTime(savedTime)
        }

        youtubePlayer = YouTubePlayer(source: .video(id: videoId), parameters: params)
    }

    private func seekTo(seconds: Double) {
        viewModel.media.updatePlaybackTime(seconds)
        guard let player = youtubePlayer else { return }
        Task { @MainActor in
            try? await player.seek(
                to: .init(value: seconds, unit: .seconds),
                allowSeekAhead: true
            )
        }
    }

    private func trackPlayback() async {
        guard let player = youtubePlayer else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { break }
            guard let time = try? await player.getCurrentTime() else { continue }
            viewModel.media.updatePlaybackTime(time.converted(to: .seconds).value)
        }
    }
}

// MARK: - Video Context Menu Handler

private final class MediaContextMenuHandler: NSObject {
    let viewModel: DocumentViewModel
    private var monitor: Any?

    init(viewModel: DocumentViewModel) {
        self.viewModel = viewModel
    }

    func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            return self.handleRightClick(event)
        }
    }

    func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleRightClick(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window,
              let webView = findWKWebView(in: window.contentView) else {
            return event
        }

        let locationInWebView = webView.convert(event.locationInWindow, from: nil)
        guard webView.bounds.contains(locationInWebView) else {
            return event
        }

        let menu = NSMenu()

        let chatItem = NSMenuItem(title: "Add Screen to Chat", action: #selector(addScreenToChat), keyEquivalent: "")
        chatItem.target = self
        chatItem.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)
        menu.addItem(chatItem)

        let noteItem = NSMenuItem(title: "Add Screen to Note", action: #selector(addScreenToNote), keyEquivalent: "")
        noteItem.target = self
        noteItem.image = NSImage(systemSymbolName: "note.text.badge.plus", accessibilityDescription: nil)
        menu.addItem(noteItem)

        menu.addItem(.separator())

        let areaItem = NSMenuItem(title: "Area Selection", action: #selector(activateAreaSelection), keyEquivalent: "")
        areaItem.target = self
        areaItem.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        menu.addItem(areaItem)

        NSMenu.popUpContextMenu(menu, with: event, for: webView)
        return nil
    }

    @objc private func addScreenToChat() {
        captureScreen { [weak self] pngData in
            guard let self, let pngData else { return }
            self.viewModel.chat.addImageAttachment(pngData, pageIndex: 0)
            self.viewModel.state.rightPanelMode = .aiChat
        }
    }

    @objc private func addScreenToNote() {
        captureScreen { [weak self] pngData in
            guard let self, let pngData else { return }
            self.viewModel.notes.addImageToNote(pngData, pageIndex: nil, source: "Video")
            self.viewModel.state.rightPanelMode = .notes
        }
    }

    @objc private func activateAreaSelection() {
        viewModel.setEditorMode(.snapshot)
    }

    private func captureScreen(completion: @escaping (Data?) -> Void) {
        guard let window = NSApp.keyWindow,
              let webView = findWKWebView(in: window.contentView) else {
            completion(nil)
            return
        }

        webView.takeSnapshot(with: nil) { image, error in
            guard let image, error == nil,
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(pngData) }
        }
    }

    private func findWKWebView(in view: NSView?) -> WKWebView? {
        guard let view else { return nil }
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = findWKWebView(in: subview) { return found }
        }
        return nil
    }

    deinit {
        remove()
    }
}
