import SwiftUI
import WebKit
import YouTubePlayerKit
import YoutubeTranscript
import OakReaderAI

/// A single timestamped line in the transcript.
struct TranscriptEntry: Identifiable {
    let id: Int        // index in array
    let offset: Double // seconds from start
    let text: String
}

/// Tab selection for the content area below video.
private enum MediaTab: String, CaseIterable {
    case transcript = "Transcript"
    case outline = "Outline"
}

/// Viewer for embed documents (YouTube).
struct MediaViewerView: View {
    let viewModel: DocumentViewModel

    @State private var youtubePlayer: YouTubePlayer?
    @State private var transcriptEntries: [TranscriptEntry] = []
    @State private var transcriptText: String?  // fallback for plain text without timestamps
    @State private var activeEntryID: Int?
    @State private var isLoadingTranscript = false
    @State private var transcriptErrorMessage: String?
    @State private var contextMenuHandler: MediaContextMenuHandler?

    // Chapter / Outline state
    @State private var selectedTab: MediaTab = .transcript
    @State private var chapters: [VideoChapter] = []
    @State private var chapterSource: ChapterSource? = nil
    @State private var chapterStatus: ChapterGenerationStatus = .idle
    @State private var activeChapterID: UUID?

    var body: some View {
        if let media = viewModel.mediaDocument {
            VStack(spacing: 0) {
                // Video player — fills full width, 16:9 aspect ratio (PINNED)
                youtubeEmbed(media: media)
                    .layoutPriority(1)

                // Metadata (PINNED)
                metadataSection(media: media)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)

                Divider()

                // Segmented tab picker (PINNED)
                Picker("", selection: $selectedTab) {
                    ForEach(MediaTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)

                Divider()

                // Scrollable tab content
                ScrollViewReader { proxy in
                    ScrollView {
                        switch selectedTab {
                        case .transcript:
                            transcriptContent(proxy: proxy)
                        case .outline:
                            outlineContent(media: media)
                        }
                    }
                    .frame(minHeight: 300)
                }
            }
            .background(OakStyle.Colors.contentBackground)
            .task { await loadOrFetchTranscript(media: media) }
            .task { await loadChapters(media: media) }
            .task(id: youtubePlayer != nil) { await trackPlayback() }
            .onAppear {
                if let videoId = extractYouTubeVideoId(from: media.sourceURL) {
                    // Restore from in-memory cache first, then fall back to DB
                    let savedTime = viewModel.lastPlaybackTime
                        ?? viewModel.libraryItem?.lastPosition
                    var params = YouTubePlayer.Parameters(autoPlay: false)
                    if let savedTime, savedTime > 0 {
                        params.startTime = .init(value: savedTime, unit: .seconds)
                    }
                    youtubePlayer = YouTubePlayer(
                        source: .video(id: videoId),
                        parameters: params
                    )
                }
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

    // MARK: - YouTube Embed

    @ViewBuilder
    private func youtubeEmbed(media: MediaDocument) -> some View {
        if let player = youtubePlayer {
            YouTubePlayerView(player) { state in
                switch state {
                case .idle:
                    ZStack {
                        Color.black
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                case .ready:
                    EmptyView()
                case .error:
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
            }
            .aspectRatio(16/9, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Metadata Section

    @ViewBuilder
    private func metadataSection(media: MediaDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(media.metadata.title)
                .font(.title2.bold())

            HStack(spacing: 8) {
                Text(media.metadata.author)
                    .foregroundStyle(.secondary)

                if let duration = media.metadata.duration {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(formatDuration(duration))
                        .foregroundStyle(.secondary)
                }

                if let publishedAt = media.metadata.publishedAt {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(publishedAt)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            if let description = media.metadata.description, !description.isEmpty {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transcript Tab Content

    @ViewBuilder
    private func transcriptContent(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !transcriptEntries.isEmpty {
                transcriptListSection(proxy: proxy)
                    .padding(.vertical, 16)
            } else if let transcript = transcriptText, !transcript.isEmpty {
                transcriptPlainSection(transcript: transcript)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            } else if isLoadingTranscript {
                transcriptLoadingSection()
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            } else if let errorMessage = transcriptErrorMessage {
                transcriptErrorSection(message: errorMessage)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transcript Sections

    @ViewBuilder
    private func transcriptListSection(proxy: ScrollViewProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(transcriptEntries) { entry in
                Button {
                    seekTo(seconds: entry.offset)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(formatTimestamp(seconds: entry.offset))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(activeEntryID == entry.id ? Color.accentColor : .secondary)
                            .frame(width: 56, alignment: .trailing)

                        Text(entry.text)
                            .font(.title3)
                            .foregroundStyle(activeEntryID == entry.id ? Color.accentColor : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(entry.id)
            }
        }
        .onChange(of: activeEntryID) { _, newID in
            guard let id = newID else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func transcriptPlainSection(transcript: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(transcript)
                .font(.body)
                .textSelection(.enabled)
                .lineSpacing(4)
        }
    }

    // MARK: - Outline Tab Content

    @ViewBuilder
    private func outlineContent(media: MediaDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch chapterStatus {
            case .completed(let source):
                chapterListSection(source: source)
                    .padding(.vertical, 16)

            case .extractingChapters:
                chapterProgressSection(message: "Extracting chapters...")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

            case .fetchingTranscript:
                chapterProgressSection(message: "Fetching transcript...")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

            case .generatingChapters:
                chapterProgressSection(message: "Generating outline...")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

            case .failed(let message):
                chapterErrorSection(message: message, media: media)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

            case .skipped(let reason):
                chapterIdleSection(reason: reason, media: media)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

            case .idle:
                chapterIdleSection(reason: nil, media: media)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func chapterListSection(source: ChapterSource) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(source == .youtube ? "Chapters" : "AI Chapters")
                    .font(.headline)

                Spacer()

                if source == .ai {
                    Text("generated by AI")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(chapters) { chapter in
                    Button {
                        seekTo(seconds: chapter.startTime)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(formatTimestamp(seconds: chapter.startTime))
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(activeChapterID == chapter.id ? Color.accentColor : .secondary)
                                .frame(width: 56, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title)
                                    .font(.body.bold())
                                    .foregroundStyle(activeChapterID == chapter.id ? Color.accentColor : .primary)

                                if let summary = chapter.summary, !summary.isEmpty {
                                    Text(summary)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(activeChapterID == chapter.id ? Color.accentColor.opacity(0.08) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func chapterProgressSection(message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func chapterErrorSection(message: String, media: MediaDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Retry") {
                Task { await generateChaptersManually(media: media) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func chapterIdleSection(reason: String?, media: MediaDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No chapters available yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if KeychainService.apiKey(for: Preferences.shared.aiProvider) != nil {
                Button("Generate AI Outline") {
                    Task { await generateChaptersManually(media: media) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("Configure an AI provider in Settings to generate chapter outlines.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private func seekTo(seconds: Double) {
        guard let player = youtubePlayer else { return }
        Task { @MainActor in
            try? await player.seek(
                to: .init(value: seconds, unit: .seconds),
                allowSeekAhead: true
            )
        }
    }

    private func extractYouTubeVideoId(from url: URL) -> String? {
        let urlString = url.absoluteString
        // youtube.com/watch?v=VIDEO_ID
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let vParam = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return vParam
        }
        // youtu.be/VIDEO_ID
        if url.host == "youtu.be" {
            return url.pathComponents.last
        }
        // youtube.com/embed/VIDEO_ID
        if urlString.contains("/embed/") {
            return url.pathComponents.last
        }
        return nil
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    private func transcriptLoadingSection() -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Fetching transcript…")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func transcriptErrorSection(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let media = viewModel.mediaDocument {
                Button("Retry") {
                    transcriptErrorMessage = nil
                    Task { await loadOrFetchTranscript(media: media) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Playback Tracking

    private func trackPlayback() async {
        guard let player = youtubePlayer else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { break }
            guard let time = try? await player.getCurrentTime() else { continue }
            let currentSeconds = time.converted(to: .seconds).value

            // Update active transcript entry
            if !transcriptEntries.isEmpty {
                let matchID = transcriptEntries.last(where: { $0.offset <= currentSeconds })?.id
                if matchID != activeEntryID {
                    activeEntryID = matchID
                }
            }

            // Update active chapter
            if !chapters.isEmpty {
                let matchChapter = chapters.last(where: { $0.startTime <= currentSeconds })?.id
                if matchChapter != activeChapterID {
                    activeChapterID = matchChapter
                }
            }
        }
    }

    // MARK: - Transcript Loading

    private func loadOrFetchTranscript(media: MediaDocument) async {
        // 1. Try loading from disk first
        if let url = media.transcriptURL,
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            let parsed = parseTranscriptText(text)
            if !parsed.isEmpty {
                transcriptEntries = parsed
            } else {
                transcriptText = text
            }
            return
        }

        // 2. Extract video ID; bail if not a YouTube video
        guard let videoId = extractYouTubeVideoId(from: media.sourceURL) else { return }

        isLoadingTranscript = true
        defer { isLoadingTranscript = false }

        do {
            // 3a. Try yt-dlp first (most reliable, uses system proxy)
            let ytDlpPath = Preferences.shared.ytDlpPath
            var entries: [TranscriptEntry] = []

            if !ytDlpPath.isEmpty, FileManager.default.isExecutableFile(atPath: ytDlpPath) {
                entries = await fetchTranscriptViaYtDlp(videoId: videoId, ytDlpPath: ytDlpPath)
            }

            // 3b. Fall back to Swift library
            if entries.isEmpty {
                do {
                    let responses = try await YoutubeTranscript.fetchTranscript(for: videoId)
                    entries = responses.enumerated().map { index, response in
                        TranscriptEntry(id: index, offset: response.offset, text: response.text)
                    }
                } catch {
                    // If yt-dlp wasn't configured, surface the error with a hint
                    if ytDlpPath.isEmpty {
                        throw error
                    }
                    // Both methods failed — yt-dlp returned nothing and library threw
                    throw error
                }
            }

            guard !entries.isEmpty else { return }

            transcriptEntries = entries

            // Cache to disk as formatted text for future opens
            let formatted = entries.map { entry in
                "\(formatTimestamp(seconds: entry.offset)) \(entry.text)"
            }.joined(separator: "\n")

            let fileURL = media.storageDirectory.appendingPathComponent("transcript.txt")
            try? formatted.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            let ytDlpPath = Preferences.shared.ytDlpPath
            if ytDlpPath.isEmpty {
                transcriptErrorMessage = "\(error.localizedDescription)\n\nTip: Install yt-dlp for more reliable transcripts (Settings > General > External Tools)."
            } else {
                transcriptErrorMessage = error.localizedDescription
            }
        }
    }

    /// Fetch transcript using yt-dlp CLI (runs as a subprocess, inherits system proxy).
    private func fetchTranscriptViaYtDlp(videoId: String, ytDlpPath: String) async -> [TranscriptEntry] {
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
                    continuation.resume(returning: [])
                    return
                }

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: [])
                    return
                }

                // Find the generated subtitle file (e.g. VIDEO_ID.en.json3)
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: tempDir, includingPropertiesForKeys: nil
                )) ?? []
                guard let subFile = files.first(where: { $0.pathExtension == "json3" }),
                      let data = try? Data(contentsOf: subFile) else {
                    continuation.resume(returning: [])
                    return
                }

                let entries = Self.parseJSON3Subtitles(data)
                continuation.resume(returning: entries)
            }
        }
    }

    /// Parse yt-dlp JSON3 subtitle format into transcript entries.
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

    /// Parse cached `[M:SS] text` or `[H:MM:SS] text` lines back into structured entries.
    private func parseTranscriptText(_ text: String) -> [TranscriptEntry] {
        let pattern = /^\[(?:(\d+):)?(\d+):(\d{2})\]\s+(.+)$/
        var entries: [TranscriptEntry] = []

        for line in text.components(separatedBy: .newlines) {
            guard let match = line.firstMatch(of: pattern) else { continue }
            let hours = match.output.1.flatMap { Double($0) } ?? 0
            let minutes = Double(match.output.2) ?? 0
            let seconds = Double(match.output.3) ?? 0
            let offset = hours * 3600 + minutes * 60 + seconds
            let entryText = String(match.output.4)
            entries.append(TranscriptEntry(id: entries.count, offset: offset, text: entryText))
        }

        return entries
    }

    private func formatTimestamp(seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "[%d:%02d:%02d]", h, m, s)
        }
        return String(format: "[%d:%02d]", m, s)
    }

    // MARK: - Chapter Loading

    private func loadChapters(media: MediaDocument) async {
        let chaptersFileURL = media.storageDirectory.appendingPathComponent("chapters.json")

        // Try loading immediately
        if let data = ChapterData.load(from: chaptersFileURL) {
            chapters = data.chapters
            chapterSource = data.source
            chapterStatus = .completed(data.source)
            return
        }

        // Poll for up to 12 seconds (post-import may still be running)
        for _ in 0..<6 {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }

            if let data = ChapterData.load(from: chaptersFileURL) {
                chapters = data.chapters
                chapterSource = data.source
                chapterStatus = .completed(data.source)
                return
            }
        }

        // Fall back to idle
        chapterStatus = .idle
    }

    private func generateChaptersManually(media: MediaDocument) async {
        chapterStatus = .generatingChapters

        guard let item = viewModel.libraryItem,
              let attachment = viewModel.libraryItem?.primaryAttachment else {
            chapterStatus = .failed("Could not determine storage location")
            return
        }

        let service = ChapterGenerationService()
        await service.run(
            itemStorageKey: item.storageKey,
            attachmentStorageKey: attachment.storageKey,
            sourceURL: media.sourceURL,
            duration: media.metadata.duration,
            transcriptAlreadyExists: media.transcriptURL != nil
        )

        // Reload from disk
        let chaptersFileURL = media.storageDirectory.appendingPathComponent("chapters.json")
        if let data = ChapterData.load(from: chaptersFileURL) {
            chapters = data.chapters
            chapterSource = data.source
            chapterStatus = .completed(data.source)
        } else {
            chapterStatus = .failed("Chapter generation did not produce results")
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
