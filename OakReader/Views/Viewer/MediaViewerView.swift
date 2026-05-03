import SwiftUI
import WebKit
import YouTubePlayerKit
import YoutubeTranscript

/// A single timestamped line in the transcript.
struct TranscriptEntry: Identifiable {
    let id: Int        // index in array
    let offset: Double // seconds from start
    let text: String
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

    var body: some View {
        if let media = viewModel.mediaDocument {
            VStack(spacing: 0) {
                // Video player — fills full width, 16:9 aspect ratio
                youtubeEmbed(media: media)
                    .layoutPriority(1)

                // Metadata + transcript fills remaining space
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            metadataSection(media: media)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 16)

                            if !transcriptEntries.isEmpty {
                                Divider()
                                transcriptListSection(proxy: proxy)
                                    .padding(.vertical, 16)
                            } else if let transcript = transcriptText, !transcript.isEmpty {
                                Divider()
                                transcriptPlainSection(transcript: transcript)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 16)
                            } else if isLoadingTranscript {
                                Divider()
                                transcriptLoadingSection()
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 16)
                            } else if let errorMessage = transcriptErrorMessage {
                                Divider()
                                transcriptErrorSection(message: errorMessage, media: media)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 16)
                            }
                        }
                    }
                }
            }
            .background(OakStyle.Colors.contentBackground)
            .task { await loadOrFetchTranscript(media: media) }
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
            }
            .onDisappear {
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
    }

    // MARK: - Transcript Sections

    @ViewBuilder
    private func transcriptListSection(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transcript")
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(transcriptEntries) { entry in
                    Button {
                        guard let player = youtubePlayer else { return }
                        Task { @MainActor in
                            try? await player.seek(
                                to: .init(value: entry.offset, unit: .seconds),
                                allowSeekAhead: true
                            )
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(formatTimestamp(seconds: entry.offset))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)

                            Text(entry.text)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 6)
                        .background(
                            activeEntryID == entry.id
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(entry.id)
                }
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
            Text("Transcript")
                .font(.headline)

            Text(transcript)
                .font(.body)
                .textSelection(.enabled)
                .lineSpacing(4)
        }
    }

    // MARK: - Helpers

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
    private func transcriptErrorSection(message: String, media: MediaDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)

            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("Retry") {
                transcriptErrorMessage = nil
                Task { await loadOrFetchTranscript(media: media) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Playback Tracking

    private func trackPlayback() async {
        guard let player = youtubePlayer, !transcriptEntries.isEmpty else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { break }
            guard let time = try? await player.getCurrentTime() else { continue }
            let currentSeconds = time.converted(to: .seconds).value
            // Find the last entry whose offset <= currentTime
            let matchID = transcriptEntries.last(where: { $0.offset <= currentSeconds })?.id
            if matchID != activeEntryID {
                activeEntryID = matchID
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
            var entries: [TranscriptEntry]
            do {
                let responses = try await YoutubeTranscript.fetchTranscript(for: videoId)
                entries = responses.enumerated().map { index, response in
                    TranscriptEntry(id: index, offset: response.offset, text: response.text)
                }
            } catch {
                // Library failed (e.g. "disabled") — try via WKWebView (uses system proxy)
                entries = try await fetchTranscriptViaWebView(videoId: videoId)
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
            transcriptErrorMessage = error.localizedDescription
        }
    }

    /// Fallback: fetch transcript via a hidden WKWebView (uses the same network/proxy
    /// path as the YouTube player, bypassing URLSession proxy issues).
    @MainActor
    private func fetchTranscriptViaWebView(videoId: String) async throws -> [TranscriptEntry] {
        let fetcher = WebViewTranscriptFetcher()
        return try await fetcher.fetch(videoId: videoId)
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
}

// MARK: - WKWebView-based Transcript Fetcher

/// Fetches YouTube transcript via a hidden WKWebView, which uses the system proxy/VPN
/// settings (same network path as the YouTube player). This works around URLSession
/// not routing through certain proxy configurations.
@MainActor
private final class WebViewTranscriptFetcher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[TranscriptEntry], any Error>?

    func fetch(videoId: String) async throws -> [TranscriptEntry] {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let config = WKWebViewConfiguration()
            let webView = WKWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
            self.webView = webView

            let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)")!
            webView.load(URLRequest(url: url))

            // Timeout after 15 seconds
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                if let self, self.continuation != nil {
                    self.continuation?.resume(throwing: URLError(.timedOut))
                    self.continuation = nil
                    self.webView = nil
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.extractTranscript(from: webView)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
            self.webView = nil
        }
    }

    private func extractTranscript(from webView: WKWebView) {
        // Step 1: Extract the captions track URL from ytInitialPlayerResponse
        let js = """
        (function() {
            try {
                var scripts = document.querySelectorAll('script');
                for (var i = 0; i < scripts.length; i++) {
                    var text = scripts[i].textContent;
                    var idx = text.indexOf('"captions":');
                    if (idx === -1) continue;
                    var sub = text.substring(idx + 11);
                    var end = sub.indexOf(',"videoDetails');
                    if (end === -1) end = sub.indexOf(',"microformat');
                    if (end === -1) continue;
                    var json = sub.substring(0, end);
                    var caps = JSON.parse(json);
                    var tracks = caps.playerCaptionsTracklistRenderer.captionTracks;
                    if (tracks && tracks.length > 0) return tracks[0].baseUrl;
                }
            } catch(e) {}
            return null;
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let trackURL = result as? String {
                    self.fetchTranscriptXML(from: trackURL, webView: webView)
                } else {
                    self.continuation?.resume(throwing: URLError(.cannotParseResponse))
                    self.continuation = nil
                    self.webView = nil
                }
            }
        }
    }

    private func fetchTranscriptXML(from trackURL: String, webView: WKWebView) {
        // Step 2: Fetch transcript XML via XMLHttpRequest (same origin, uses WKWebView network)
        let escapedURL = trackURL.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        new Promise(function(resolve, reject) {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', '\(escapedURL)');
            xhr.onload = function() { resolve(xhr.responseText); };
            xhr.onerror = function() { reject('XHR failed'); };
            xhr.send();
        });
        """

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let value = try await webView.callAsyncJavaScript(js, contentWorld: .page)
                if let xmlString = value as? String {
                    let entries = self.parseTranscriptXML(xmlString)
                    self.continuation?.resume(returning: entries)
                } else {
                    self.continuation?.resume(throwing: URLError(.cannotDecodeContentData))
                }
            } catch {
                self.continuation?.resume(throwing: error)
            }
            self.continuation = nil
            self.webView = nil
        }
    }

    private func parseTranscriptXML(_ xmlString: String) -> [TranscriptEntry] {
        guard let regex = try? NSRegularExpression(
            pattern: "<text start=\"([^\"]*)\" dur=\"([^\"]*)\">([^<]*)</text>"
        ) else { return [] }

        let range = NSRange(xmlString.startIndex..., in: xmlString)
        let matches = regex.matches(in: xmlString, range: range)

        return matches.enumerated().map { index, match in
            let offsetStr = (xmlString as NSString).substring(with: match.range(at: 1))
            let text = (xmlString as NSString).substring(with: match.range(at: 3))
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")

            return TranscriptEntry(
                id: index,
                offset: Double(offsetStr) ?? 0,
                text: text
            )
        }
    }
}
